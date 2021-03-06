{-# LANGUAGE CPP                #-}

module Check where

import Test.QuickCheck
import Test.QuickCheck.Monadic (assert, monadicIO, run, PropertyM (..) )

import qualified Parallel as P

import Control.Exception (catch)
import Control.Monad

import qualified Data.ByteString.Lazy as L
import qualified Data.ByteString.Lazy.Char8 as LC8
import Data.Maybe

import System.Random
import System.Process
import System.Posix
import System.Exit
import System.Directory
import System.IO.Unsafe
import System.Timeout

import Data.ByteString.Char8 as L8

#ifdef NET

import Network hiding (accept, sClose)
import Network.Socket hiding (send, sendTo, recv, recvFrom) 
import Network.Socket.ByteString (send, sendTo, recv, recvFrom, sendAll)
import Control.Concurrent
import Control.Concurrent.Thread.Delay

#endif

import Exceptions
import Mutation

processPar = P.processPar
parallelism = P.parallelism

getFileSize :: String -> IO FileOffset
getFileSize path = do
    stat <- getFileStatus path
    return (fileSize stat)

--bhandler :: SomeException -> IO L.ByteString
--bhandler x = return (LC8.pack "") --Prelude.putStrLn (show x)--return ()


--quickhandler x = Nothing

type Cmd = (FilePath,[String])

has_failed :: ExitCode -> Bool
has_failed (ExitFailure n) =
    (n < 0 || (n > 128 && n < 143))
has_failed ExitSuccess = False

write :: L.ByteString -> FilePath -> IO ()
write x filename =  Control.Exception.catch (L.writeFile filename x) handler

exec :: Cmd -> IO ExitCode
exec (prog, args) = rawSystem prog args

save filename outdir = 
  do 
     seed <- (randomIO :: IO Int)
     copyFile filename (outdir ++ "/" ++ show seed ++ "." ++ filename)
 
report value filename outdir =
  do 
     seed <- (randomIO :: IO Int)
     LC8.writeFile (outdir ++ "/" ++ show seed ++ "." ++ filename ++ ".val") (LC8.pack (show value))
     copyFile filename (outdir ++ "/" ++ show seed ++ "." ++ filename)
    
freport value orifilename filename outdir =
  do 
     seed <- (randomIO :: IO Int)
     LC8.writeFile (outdir ++ "/" ++ show seed ++ "." ++ filename ++ ".val") (LC8.pack (show value))
     copyFile orifilename (outdir ++ "/" ++ show seed ++ "." ++ filename ++ ".ori")
     copyFile filename (outdir ++ "/" ++ show seed ++ "." ++ filename)
     copyFile filename (outdir ++ "/last")

rreport value filename outdir =
  do 
     seed <- (randomIO :: IO Int)
     copyFile filename (outdir ++ "/red." ++ show seed ++ "." ++ filename)
 

{-

checkprop filename prog args encode outdir x = 
         monadicIO $ do
         run $ Control.Exception.catch (L.writeFile filename (encode x)) handler
         size <- run $ getFileSize filename
         if size == 0 
            then Test.QuickCheck.Monadic.assert True 
         else (
           do 
               let varepname = filename ++ ".vreport.out"
               seed <- run (randomIO :: IO Int)
               ret <- run $ rawSystem "/usr/bin/valgrind" (["--log-file="++ varepname, "--quiet", prog] ++ args)
               size <- run $ getFileSize varepname --"vreport.out"
               if size > 0 
                  then ( 
                      do 
                        run $ copyFile varepname (outdir ++ "/" ++ "vreport.out."++ show seed)
                        -- run $ copyFile "vreport.out" (outdir ++ "/" ++ "vreport.out."++ show seed)
                        run $ copyFile filename (outdir ++ "/" ++ filename ++ "."++ show seed)
                        Test.QuickCheck.Monadic.assert True
                      )
                  else Test.QuickCheck.Monadic.assert True
               )
timed_encode f x = unsafePerformIO ( 
             do r <- timeout 10000 $ evaluate $ f x
                case r of
                  Just x -> return x --unsafePerformIO $ return x
                  Nothing -> return $ LC8.pack "" --unsafePerformIO $ return $ LC8.pack ""
             )


--mutprop :: (Show a, Mutation a,Arbitrary a) => FilePath  -> String -> [String]  -> (a -> L.ByteString) -> (L.ByteString -> a) -> [Char] -> [a] ->  Property
mutprop filename prog args encode outdir maxsize vals = 
         noShrinking $ monadicIO $ do
         r <- run (randomIO :: IO Int)
         idx <- run $ return (r `mod` (Prelude.length vals))
         size <- run $ return (r `mod` maxsize)
         run $ print "Mutating.."

         x <- run $ return $ vals !! idx
         y <- run $ generate $ resize size $ mutt $ x
         --run $ print "Original:"
         --run $ print ("Idx: "++show(idx))

         --run $ print x --Control.Exception.catch (print x) handler

         --run $ print y --Control.Exception.catch (print y) handler
         run $ print "Encoding.."

         z <- run $ Control.Exception.catch (evaluate $ timed_encode encode y) enc_handler
         let tmp_filename = ".qf." ++ filename
         run $ (L.writeFile tmp_filename z)
         run $ system $ "radamsa" ++ "<" ++ tmp_filename ++ " > " ++ filename

         run $ print "Executing.."

         size <- run $ getFileSize filename 
         if size == 0 
            then Test.QuickCheck.Monadic.assert True 
         else (
           do 
           seed <- run (randomIO :: IO Int)
           ret <- run $ rawSystem prog args
           --ret <- run $ call_honggfuzz filename prog args undefined outdir

           case ret of
              ExitFailure x -> (
                                
                                if ((x < 0 || x > 128) && x /= 143) then
                                 do 
                                   run $ copyFile filename (outdir ++ "/" ++ show seed ++ "." ++ filename)
                                   Test.QuickCheck.Monadic.assert True
                                 else
                                   Test.QuickCheck.Monadic.assert True
                )
              _             -> Test.QuickCheck.Monadic.assert True
           )
         --)


-}

exec_honggfuzz filename (prog,args) seed outdir = 
   rawSystem "honggfuzz" (["-q", "-v", "-n", "2", "-N", "5", "-r", "0.00001", "-t","60", "-f", filename,  "-W", outdir, "--", prog] ++ args)

prop_HonggfuzzExec :: Show a => FilePath -> Cmd -> (a -> L.ByteString) -> FilePath -> a -> Property
prop_HonggfuzzExec filename pcmd encode outdir x = 
         noShrinking $ monadicIO $ do
         run $ write (encode x) filename
         size <- run $ getFileSize filename
         if size == 0 
            then assert True
         else (
           do 
             ret <- run $ exec_honggfuzz filename pcmd undefined outdir
             assert True
             )
         

exec_zzuf infile outfile = 
  system $ "zzuf  -r 0.004:0.000001 -s" ++ show seed ++ " < " ++ infile ++ " > " ++ outfile
    where seed = unsafePerformIO (randomIO :: IO Int)

prop_ZzufExec :: Show a => FilePath -> Cmd -> (a -> L.ByteString) -> FilePath -> a -> Property
prop_ZzufExec filename pcmd encode outdir x = 
         monadicIO $ do
         let tmp_filename = ".qf." ++ filename

         run $ write (encode x) tmp_filename
         run $ exec_zzuf tmp_filename filename
         ret <- run $ exec pcmd
         case not (has_failed ret) of
           False -> (do 
                        run $ freport x tmp_filename filename outdir
                        assert False
               )
           _     -> assert True
           

exec_radamsa infile outfile =
 rawSystem "radamsa" [infile, "-o", outfile]

prop_RadamsaExec :: Show a => FilePath -> Cmd -> (a -> L.ByteString) -> FilePath -> a -> Property
prop_RadamsaExec filename pcmd encode outdir x = 
         noShrinking $ monadicIO $ do
         let tmp_filename = ".qf." ++ filename

         run $ write (encode x) tmp_filename
         run $ exec_radamsa tmp_filename filename
         ret <- run $ exec pcmd
         case not (has_failed ret) of
             False -> (do 
                        run $ freport x tmp_filename filename outdir
                        assert False)
             _     -> (assert True) 
           

prop_Exec :: Show a => FilePath -> Cmd -> (a -> L.ByteString) -> FilePath -> a -> Property
prop_Exec filename pcmd encode outdir x = 
         monadicIO $ do
         run $ write (encode x) filename
         size <- run $ getFileSize filename
         if size == 0 
            then assert True
         else (
           do 
           ret <- run $ exec pcmd
           case not (has_failed ret) of
              False -> (do 
                        run $ report x filename outdir
                        assert False
               )
              _             -> assert True
           )


prop_Red :: Show a => FilePath -> Cmd -> (a -> L.ByteString) -> FilePath -> a -> Property
prop_Red filename pcmd encode outdir x = 
         monadicIO $ do
         run $ write (encode x) filename
         ret <- run $ exec pcmd
         case not (has_failed ret) of
              False -> (do 
                        run $ rreport x filename outdir
                        assert False
               )
              _             -> assert True
         



prop_Gen :: Show a => FilePath -> Cmd -> (a -> L.ByteString) -> FilePath -> a -> Property
prop_Gen filename pcmd encode outdir x = 
         noShrinking $ monadicIO $ do
         run $ write (encode x) filename
         size <- run $ getFileSize filename
         if size == 0 
            then assert True
         else (
           do
           run $ save filename outdir
           assert True
           )

#ifdef NET

serve :: PortNumber -> [L8.ByteString] -> IO ()
serve port xs = withSocketsDo $ do
    sock <- listenOn $ PortNumber port
    serve_loop sock xs

serve_loop sock (x:xs) = do
   Prelude.putStrLn "Accepting connection.."
   (conn, _) <- accept sock
   forkIO $ body conn
   serve_loop sock xs
  where
   body c = do sendAll c x
               sClose c

serve_loop _ [] = error "Empty list!"

serveprop port _ encode x =  
        noShrinking $ monadicIO $ do
           run $ serve port (encode x)
           Test.QuickCheck.Monadic.assert True

cconnect :: PortNumber -> String -> [L8.ByteString] -> IO ()
cconnect port host xs = withSocketsDo $ do
    Prelude.putStrLn host
    Prelude.putStrLn (show port)
    addrInfo <- getAddrInfo Nothing (Just host) (Just $ show port)

    let serverAddr = Prelude.head addrInfo
    sock <- socket (addrFamily serverAddr) Stream defaultProtocol
    --sock <- conn $ PortNumber port
    connect sock (addrAddress serverAddr)
    cconect_loop sock xs

cconect_loop sock (x:xs) = do
   Prelude.putStrLn "Sending data .."
   send sock x
   --(conn, _) <- accept sock
   --forkIO $ body conn
   cconnect_loop sock xs
  --where
  -- body c = do sendAll c x
  --             sClose c

cconnect_loop _ [] = error "Empty list!"

cconnectprop port host encode x =  
        noShrinking $ monadicIO $ do
           run $ cconnect port host (encode x)
           Test.QuickCheck.Monadic.assert True

#endif
