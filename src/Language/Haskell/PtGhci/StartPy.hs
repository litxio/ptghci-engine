{-# LANGUAGE ForeignFunctionInterface, ExtendedDefaultRules #-}

module Language.Haskell.PtGhci.StartPy where

import Language.Haskell.PtGhci.Prelude
import Foreign.C.Types
import Foreign.C.String
import Foreign.Ptr
import Foreign.Storable
import System.Environment
import Control.Concurrent.Async
import Control.Concurrent.MVar
import System.FilePath
import Data.String
import Foreign.Marshal.Array
import Data.Char (ord)
import Paths_ptghci
import Language.Haskell.PtGhci.Env
import Language.Haskell.PtGhci.Log

data PyObject = PyObject
type PyObjectPtr = Ptr PyObject

-- | Starts the Python interpreter and hands over control
startPythonApp :: Env -> (String, String, String, String) -> IO ()
startPythonApp env (requestAddr, controlAddr, stdoutAddr, stderrAddr) = do
  ourpp <- getDataFileName "pybits"
  pythonPath0 <- lookupEnv "PYTHONPATH"
  let pythonPath = case pythonPath0 of
                     Nothing -> ourpp
                     Just s -> s ++ (searchPathSeparator:ourpp)
  debug env $ "Setting PYTHONPATH to \""++pythonPath++"\""
  setEnv "PYTHONPATH" pythonPath
  setEnv "PTGHCI_REQUEST_ADDR" requestAddr
  setEnv "PTGHCI_CONTROL_ADDR" controlAddr
  setEnv "PTGHCI_STDOUT_ADDR" stdoutAddr
  setEnv "PTGHCI_STDERR_ADDR" stderrAddr
  printDebugInfo env
  s <- newCString $ unlines [ "import os, sys"
                             ,"from ptghci.app import App"
                             ,"app = App()"
                             ,"app.run()"]

  -- Run the Python interpreter in an OS thread while having this thread listen
  -- for an AsyncCancelled exception indicating we should exit.
  done <- newEmptyMVar
  withAsyncBound (runPy s done)
    $ \_ -> (handle onInterrupt $ takeMVar done)
  where
    runPy s done = do
      pyInitialize
      res <- pyRunSimpleString s
      when (res == -1) $
        logerr env $ "Python exited with an exception"
      pyFinalize
      putMVar done ()

    -- We want to kill the Python interpreter cleanly when we get an
    -- AsyncCanclled exception, so we arrange to handle that exception by
    -- scheduling a Python exception (EOFError) to be thrown
    onInterrupt :: AsyncCancelled -> IO ()
    onInterrupt _ = do
      pendingPtr <- createPendingCallPtr throwPyExit
      gstate <- pyGILStateEnsure
      void $ pyAddPendingCall pendingPtr
      pyGILStateRelease gstate

    throwPyExit = do
      eofErr <- peek pyEOFError
      msg <- newCString "ptGHCi Haskell engine thread exited"
      pyErrSetString eofErr msg
      return (-1)

printDebugInfo :: Env -> IO ()
printDebugInfo env = do
  debug env $ "Python thread starting"
  pyVer <- pyGetVersion >>= peekCString
  pyPath <- pyGetPath >>= peekCWString
  debug env $ "Python version " ++ pyVer
  debug env $ "Python module path: " ++ pyPath


foreign import ccall "Py_Main" pyMain :: CInt -> Ptr (Ptr CInt) -> IO CInt
foreign import ccall "PyRun_SimpleString" pyRunSimpleString :: CString -> IO CInt
foreign import ccall "Py_Initialize" pyInitialize :: IO ()
foreign import ccall "Py_Finalize" pyFinalize :: IO ()
foreign import ccall "PyErr_SetInterrupt" pyErrSetInterrupt :: IO ()
foreign import ccall "PyErr_CheckSignals" pyErrCheckSignals :: IO CInt
foreign import ccall "PyErr_SetString" pyErrSetString :: PyObjectPtr -> CString -> IO ()
foreign import ccall "Py_AddPendingCall" pyAddPendingCall :: FunPtr (IO CInt) -> IO CInt

-- The result of pyGILStateEnsure is actually an enum not int so I am violating
-- an abstraction here.
foreign import ccall "PyGILState_Ensure" pyGILStateEnsure :: IO CInt
foreign import ccall "PyGILState_Release" pyGILStateRelease :: CInt -> IO ()
foreign import ccall "&PyExc_EOFError" pyEOFError :: Ptr PyObjectPtr

foreign import ccall "Py_GetVersion" pyGetVersion :: IO CString
foreign import ccall "Py_GetPath" pyGetPath :: IO CWString

foreign import ccall "wrapper" createPendingCallPtr :: IO CInt -> IO (FunPtr (IO CInt))
