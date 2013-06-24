-- | Exception handling and resource management integrated with proxies

{-# LANGUAGE RankNTypes, CPP #-}

module Pipes.Safe (
{-
    -- * SafeP
    SafeP,
    runSafeP,
    runSafeK,

    -- * SafeIO
    SafeIO,
    trySafeIO,
    trySaferIO,
    runSafeIO,
    runSaferIO,

    -- * Checking Exceptions
    -- $check
    CheckP(..),
    tryIO,
    maskIO,

    -- * Exception Handling
    throw,
    catch,
    handle,

    -- * Finalization
    onAbort,
    finally,
    bracket,
    bracket_,
    bracketOnAbort,

    -- * Utilities

    -- ** Handle allocation
    withFile,

    -- ** String I/O
    -- $string
    readFileS,
    writeFileD,

    -- * Re-exports
    -- $reexports
    module Control.Exception,
    module Control.Proxy.Trans.Either
-}
    ) where

-- #if MIN_VERSION_base(4,6,0)
-- #else
import Prelude hiding (catch)
-- #endif
import qualified System.IO as IO

import Control.Applicative (Applicative(pure, (<*>)), (<*))
import qualified Control.Exception as Ex
import Control.Monad.IO.Class (MonadIO(liftIO))
import Control.Monad.Morph (MFunctor(hoist))
import Control.Monad.Trans.Class (MonadTrans(lift))
import Control.Monad.Trans.Error (
    ErrorT(ErrorT, runErrorT), Error(noMsg, strMsg), throwError, catchError )
import Control.Monad.Trans.Reader (ReaderT(ReaderT, runReaderT), asks)
import Control.Monad.Trans.State.Strict (StateT, evalStateT, get, put)
import Pipes
import qualified Pipes.Lift as PL
import System.IO.Error (userError)

newtype Mask = Mask { unMask :: forall a . IO a -> IO a }

data Finalizers = Finalizers
    { upstream   :: [Maybe (IO ())]
    , downstream :: [Maybe (IO ())]
    }

{-| 'SafeIO' masks asynchronous exceptions by default and only unmasks them
    during 'try' or 'tryIO' blocks.  This ensures that all asynchronous
    exceptions are checked, too.
-}
newtype SafeIO r = SafeIO { unSafeIO
    :: ErrorT Ex.SomeException (StateT Finalizers (ReaderT Mask IO)) r }

instance Functor SafeIO where
    fmap f m = SafeIO (fmap f (unSafeIO m))

instance Applicative SafeIO where
    pure r  = SafeIO (pure r)
    f <*> x = SafeIO (unSafeIO f <*> unSafeIO x)

instance Monad SafeIO where
    return r = SafeIO (return r)
    m >>= f  = SafeIO (unSafeIO m >>= \a -> unSafeIO (f a))

instance Error Ex.SomeException where
    strMsg str = Ex.toException (userError str)

class (MonadIO m) => MonadSafe m where
    -- | Analogous to 'Ex.throwIO' from @Control.Exception@
    throw :: (Ex.Exception e) => e -> m r
    -- | Analogous to 'Ex.catch' from @Control.Exception@
    catch :: (Ex.Exception e) => m r -> (e -> m r) -> m r
    {-| Check all exceptions for an 'IO' action, unmasking asynchronous
        exceptions
    -}
    tryIO :: IO r -> m r
    getFinalizers :: m Finalizers
    putFinalizers :: Finalizers -> m ()

instance MonadIO SafeIO where
    liftIO io = SafeIO $ ErrorT $ lift $ lift $ Ex.try io

instance MonadSafe SafeIO where
    throw e = SafeIO $ throwError (Ex.toException e)
    catch m f = SafeIO $ unSafeIO m `catchError` (\someExc ->
        case Ex.fromException someExc of
            Nothing -> throwError someExc
            Just e  -> unSafeIO (f e) )
    tryIO  io = SafeIO $ ErrorT $ lift $ do
        restore <- asks unMask
        lift $ Ex.try (restore io)
    getFinalizers = SafeIO $ lift get
    putFinalizers finalizers = SafeIO $ lift $ put finalizers

instance (MonadSafe m) => MonadSafe (Proxy a' a b' b m) where
    throw = lift . throw
    catch = PL.liftCatchError catch
    tryIO = lift . tryIO
    getFinalizers = lift getFinalizers
    putFinalizers = lift . putFinalizers

markStartingPoint :: (MonadSafe m) => m ()
markStartingPoint = do
    Finalizers up dn <- getFinalizers
    putFinalizers (Finalizers (Nothing:up) (Nothing:dn))

newFinalizers :: (MonadSafe m) => m (IO (), IO ())
newFinalizers = do
    Finalizers ups dns <- getFinalizers
    let (newUps, ups') = new ups
        (newDns, dns') = new dns
    putFinalizers (Finalizers ups' dns')
    return (newUps, newDns)
  where
    new = go []
    go as mas = case mas of
        []           -> (sequence_ (reverse as), []  )
        Nothing:mas' -> (sequence_ (reverse as), mas')
        Just a :mas' -> go (a:as) mas'

_promptly :: (MonadSafe m) => m r -> m r
_promptly m = do
    markStartingPoint
    (m     >>= (\r -> cleanup >> return  r                     ))
       `catch` (\e -> cleanup >> throw  (e :: Ex.SomeException))
  where
    cleanup = do
        (up, dn) <- newFinalizers
        liftIO up `catch` (\e -> liftIO dn >> throw (e :: Ex.SomeException))
        liftIO dn

promptly :: (MonadSafe m) => Effect' m r -> Effect' m r
promptly = _promptly

_tryWith
    :: (((forall a . IO a -> IO a) -> IO (Either Ex.SomeException r))
        -> IO (Either Ex.SomeException r) )
    -> SafeIO r
    -> IO (Either Ex.SomeException r)
_tryWith mask sio = mask $ \restore ->
    runReaderT (evalStateT (runErrorT (unSafeIO sio0)) s0) (Mask restore)
  where
    sio0 = _promptly sio
    s0   = Finalizers [] []

_rethrow :: IO (Either Ex.SomeException r) -> IO r
_rethrow io = do
    x <- io
    case x of
        Left  e -> Ex.throw e
        Right r -> return r

trySafeIO :: SafeIO r -> IO (Either Ex.SomeException r)
trySafeIO = _tryWith Ex.mask
{-# INLINABLE trySafeIO #-}

trySaferIO :: SafeIO r -> IO (Either Ex.SomeException r)
trySaferIO = _tryWith Ex.uninterruptibleMask
{-# INLINABLE trySaferIO #-}

{-| 'runSafeIO' masks asynchronous exceptions using 'Ex.mask' and only unmasks
    them during 'try' or 'tryIO'.

    'runSafeIO' is NOT a monad morphism.
-}
runSafeIO :: SafeIO r -> IO r
runSafeIO sio = _rethrow (trySafeIO sio)
{-# INLINABLE runSafeIO #-}

{-| 'runSaferIO' masks asynchronous exceptions using 'Ex.uninterruptibleMask'
    and only unmasks them during 'try' or 'tryIO'.

    'runSaferIO' is NOT a monad morphism.
-}
runSaferIO :: SafeIO e -> IO e
runSaferIO sio = _rethrow (trySaferIO sio)
{-# INLINABLE runSaferIO #-}

-- | Analogous to 'Ex.handle' from @Control.Exception@
handle :: (Ex.Exception e, MonadSafe m) => (e -> m r) -> m r -> m r
handle = flip catch
{-# INLINABLE handle #-}

{- I don't export 'register' only because people rarely want to guard solely
   against premature termination.  Usually they also want to guard against
   exceptions, too.

    @registerK = (register .)@ should satisfy the following laws:

* 'registerK' defines a functor from finalizers to functions:

> registerK m1 . registerK m2 = registerK (m2 >> m1)
> 
> registerK (return ()) = id

* 'registerK' is a functor between Kleisli categories:

> registerK m (p1 >=> p2) = registerK m p1 >=> registerK m p2
>
> registerK m return = return

    These laws are not provable using the current set of proxy laws, mainly
    because the proxy laws do not yet specify how proxies interact with the
    'Arrow' instance for the Kleisli category.  However, I'm reasonably sure
    that when I do specify this interaction that the above laws will hold.

    For now, just consider the above laws the contract for 'register' and
    consider any violations of the above laws as bugs.
-}
register
    :: (MonadSafe m)
    => IO ()
    -> Proxy a' a b' b m r
    -> Proxy a' a b' b m r
register h p = up >\\ p //> dn
  where
    dn b = do
        old <- getFinalizers
        putFinalizers $ old { upstream = Just h:upstream old }
	b' <- respond b
	putFinalizers old
	return b'
    up a' = do
        old <- getFinalizers
        putFinalizers $ old { downstream = Just h:downstream old }
        a  <- request a'
        putFinalizers old
        return a

{- $check
    The following @try@ functions are the only way to convert 'IO' actions to
    'SafeIO'.  These functions check all exceptions, including asynchronous
    exceptions, and store them in the 'SafeP' proxy transformer.
-}

{-| Use 'try' to retroactively check all exceptions for proxies that implement
    'CheckP'.

    'try' is /almost/ a proxy morphism (See @Control.Proxy.Morph@ from @pipes@
    for the full list of laws).  The only exception is the following law:

> try (return x) = return x

    The left-hand side unmasks asynchronous exceptions and checks them
    immediately, whereas the right-hand side delays asynchronous exceptions
    until the next 'try' or 'tryIO' block.
-}

{-| Similar to 'Ex.onException' from @Control.Exception@, except this also
    protects against:

    * premature termination, and

    * exceptions in other proxy stages.

    The first argument lifts 'onAbort' to work with other base monads.  Use
    'id' if your base monad is already 'SafeIO'.

    @(onAbort morph fin)@ is a monad morphism:

> onAbort morph fin $ do x <- m  =  do x <- onAbort morph fin m
>                        f x           onAbort morph fin (f x)
>
> onAbort morph fin (return x) = return x

    'onAbort' ensures finalizers are called from inside to out:

> onAbort morph fin1 . onAbort morph fin2 = onAbort morph (fin2 >> fin1)
>
> onAbort morph (return ()) = id
-}
onAbort
    :: (MonadSafe m)
    => IO s                -- ^ Action to run on abort
    -> Proxy a' a b' b m r -- ^ Guarded computation
    -> Proxy a' a b' b m r
onAbort after p =
    register (after >> return ()) p
        `catch` (\e -> do
            liftIO after
            throw (e :: Ex.SomeException) )
{-# INLINABLE onAbort #-}

{-| Analogous to 'Ex.finally' from @Control.Exception@

    The first argument lifts 'finally' to work with other base monads.  Use 'id'
    if your base monad is already 'SafeIO'.

> finally morph after p = do
>     r <- onAbort morph after p
>     hoist morph $ maskIO after
>     return r
-}
finally
    :: (MonadSafe m)
    => Proxy a' a b' b m r -- ^ Guarded computation
    -> IO s                -- ^ Guaranteed final action
    -> Proxy a' a b' b m r
finally p after = do
    r <- onAbort after p
    liftIO after
    return r
{-# INLINABLE finally #-}

{-| Analogous to 'Ex.bracket' from @Control.Exception@

    The first argument lifts 'bracket' to work with other base monads.  Use 'id'
    if your base monad is already 'SafeIO'.

    'bracket' guarantees that if the resource acquisition completes, then the
    resource will be released.

> bracket morph before after p = do
>     h <- hoist morph $ maskIO before
>     finally morph (after h) (p h)
-}
bracket
    :: (MonadSafe m)
    => IO h                        -- ^ Acquire resource
    -> (h -> IO r')                -- ^ Release resource
    -> (h -> Proxy a' a b' b m r)  -- ^ Use resource
    -> Proxy a' a b' b m r
bracket before after p = do
    h <- liftIO before
    p h `finally` after h
{-# INLINABLE bracket #-}

{-| Analogous to 'Ex.bracket_' from @Control.Exception@

    The first argument lifts 'bracket_' to work with any base monad.  Use 'id'
    if your base monad is already 'SafeIO'.

> bracket_ morph before after p = do
>     hoist morph $ maskIO before
>     finally morph after p
-}
bracket_
    :: (MonadSafe m)
    => IO s                 -- ^ Acquire resource
    -> IO t                 -- ^ Release resource
    -> Proxy a' a b' b m r  -- ^ Use resource
    -> Proxy a' a b' b m r
bracket_ before after p = do
    liftIO before
    p `finally` after
{-# INLINABLE bracket_ #-}

{-| Analogous to 'Ex.bracketOnError' from @Control.Exception@

    The first argument lifts 'bracketOnAbort' to work with any base monad.  Use
    'id' if your base monad is already 'SafeIO'.

> bracketOnAbort morph before after p = do
>     h <- hoist morph $ maskIO before
>     onAbort morph (after h) (p h)
-}
bracketOnAbort
    :: (MonadSafe m)
    => IO h                        -- ^ Acquire resource
    -> (h -> IO s)                 -- ^ Release resource
    -> (h -> Proxy a' a b' b m r)  -- ^ Use resource
    -> Proxy a' a b' b m r
bracketOnAbort before after p = do
    h <- liftIO before
    onAbort (after h) (p h)
{-# INLINABLE bracketOnAbort #-}

-- | Safely allocate a 'IO.Handle' within a managed 'Proxy'
withFile
    :: (MonadSafe m)
    => FilePath                            -- ^File
    -> IO.IOMode                           -- ^IO Mode
    -> (IO.Handle -> Proxy a' a b' b m r)  -- ^Continuation
    -> Proxy a' a b' b m r
withFile file ioMode = bracket (IO.openFile file ioMode) IO.hClose
{-# INLINABLE withFile #-}

{- $string
    Note that 'String's are very inefficient, and I will release future separate
    packages with 'ByteString' and 'Text' operations.  I only provide these to
    allow users to test simple I/O without requiring any additional library
    dependencies.
-}

{-| Read from a file, lazily opening the 'IO.Handle' and automatically closing
    it afterwards
-}
readFile :: FilePath -> () -> Producer String SafeIO ()
readFile file () = withFile file IO.ReadMode $ \handle -> do
    let go = do
            eof <- tryIO $ IO.hIsEOF handle
            if eof
                then return ()
                else do
                    str <- tryIO $ IO.hGetLine handle
                    respond str
                    go
    go
{-# INLINABLE readFile #-}

{-| Write to a file, lazily opening the 'IO.Handle' and automatically closing it
    afterwards
-}
writeFile :: FilePath -> () -> Consumer String SafeIO r
writeFile file () = withFile file IO.WriteMode $ \handle -> forever $ do
    str <- request ()
    tryIO $ IO.hPutStrLn handle str
{-# INLINABLE writeFile #-}

{- $reexports
    @Control.Proxy.Trans.Either@ only re-exports 'EitherP', 'runEitherP', and
    'runEitherK'.

    @Control.Exception@ only re-exports 'SomeException' and 'Exception'.
-}
