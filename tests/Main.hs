import           Data.Tagged (Tagged (..), untag)

import           Test.Framework (Test, defaultMain, testGroup)

import qualified Data.HashPSQ         as HashPSQ
import qualified Data.IntPSQ          as IntPSQ
import qualified Data.IntPSQ.Tests
import qualified Data.PSQ.Class.Tests
import qualified Data.PSQ             as PSQ

main :: IO ()
main = defaultMain
    [ testGroup "Data.PSQ.Class.Tests IntPSQ"  $ untag
        (Data.PSQ.Class.Tests.tests :: Tagged IntPSQ.IntPSQ         [Test])
    , testGroup "Data.PSQ.Class.Tests PSQ"     $ untag
        (Data.PSQ.Class.Tests.tests :: Tagged (PSQ.PSQ Int)         [Test])
    , testGroup "Data.PSQ.Class.Tests HashPSQ" $ untag
        (Data.PSQ.Class.Tests.tests :: Tagged (HashPSQ.HashPSQ Int) [Test])
    ]