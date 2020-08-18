{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Main
  (
    main
  ) where

import           Control.Lens                    ((&), (.~))
import           Data.Aeson                      (FromJSON, parseJSON,
                                                  withObject, (.!=), (.:),
                                                  (.:?))
import qualified Data.ByteString.Lazy            as LB (ByteString)
import           Data.Streaming.Network.Internal (HostPreference (Host))
import           Network.HTTP.Client             (Manager,
                                                  defaultManagerSettings,
                                                  managerConnCount,
                                                  managerResponseTimeout,
                                                  newManager,
                                                  responseTimeoutMicro)
import           Network.URI                     (URI (..), URIAuth (..),
                                                  parseURI)
import qualified Network.Wai.Handler.Warp        as W (defaultSettings,
                                                       runSettings, setHost,
                                                       setPort)
import           Network.Wai.Handler.WebSockets  (websocketsOr)
import           Network.Wai.Middleware.Cors     (CorsResourcePolicy (..), cors,
                                                  simpleCorsResourcePolicy)
import qualified Network.WebSockets              as WS (defaultConnectionOptions)
import           Network.Wreq                    (Options, Response, manager)
import           Web.Scotty                      (ScottyM, delete, get,
                                                  middleware, options, post,
                                                  put, scottyApp)
import           Yuntan.Gateway

import qualified Data.Yaml                       as Y
import           Options.Applicative

newtype Options' = Options' {getConfigFile :: String}

parser :: Parser Options'
parser = Options' <$> strOption (long "config"
                                <> short 'c'
                                <> metavar "FILE"
                                <> help "config file."
                                <> value "config.yaml")

data AppConfig = AppConfig
  { key     :: AppKey
  , secret  :: AppSecret
  , baseUrl :: String
  , secure  :: Bool
  , proxy   :: Bool -- flag of only proxy
  }

data Config = Config
  { appList     :: [AppConfig]
  , connTimeout :: Int
  -- default 10 seconds, unit seconds
  , connPool    :: Int
  -- default 10
  , host        :: String
  , port        :: Int
  }

instance FromJSON AppConfig where
  parseJSON = withObject "AppConfig" $ \o -> do
    key     <- o .:  "key"
    secret  <- o .:  "secret"
    baseUrl <- o .:  "baseUrl"
    secure  <- o .:? "secure" .!= False
    proxy   <- o .:? "proxy"  .!= False
    return AppConfig{..}

instance FromJSON Config where
  parseJSON = withObject "Config" $ \o -> do
    appList     <- o .:  "appList"
    connPool    <- o .:? "connPool"    .!= 10
    connTimeout <- o .:? "connTimeout" .!= 10
    host        <- o .:? "host"        .!= "127.0.0.1"
    port        <- o .:? "port"        .!= 3000
    return Config{..}


main :: IO ()
main = execParser opts >>= program
  where
    opts = info (helper <*> parser)
      ( fullDesc
     <> progDesc "Simple Gateway"
     <> header "simple-gateway - Simple Gateway" )

program :: Options' -> IO ()
program Options'{getConfigFile=configPath} = do
  c <- Y.decodeFileEither configPath
  case c of
    Left e     -> print e
    Right Config{..} -> do
      -- let opts = def {settings = setPort port
      --                          $ setHost (Host host) (settings def)}
      mgr <- newManager defaultManagerSettings
                { managerConnCount = connPool
                , managerResponseTimeout = responseTimeoutMicro $ connTimeout * 10000000
                }

      let provider = newProvider
            { getAppByKey = getAppAndInitail mgr appList
            }

      sapp <- scottyApp $ application provider
      let app = websocketsOr WS.defaultConnectionOptions (wsProxyHandler provider) sapp
      W.runSettings (W.setPort port . W.setHost (Host host) $ W.defaultSettings) app


findApp :: [AppConfig] -> AppKey -> Maybe AppConfig
findApp [] _ = Nothing
findApp (x:xs) k = if key x == k then Just x
                                 else findApp xs k

getAppAndInitail :: Manager -> [AppConfig] -> AppKey -> IO (Maybe App)
getAppAndInitail mgr configs k =
  case findApp configs k of
    Nothing -> return Nothing
    Just AppConfig{..} -> do
      let app = newApp key secret secure proxy
          app' = app
            { doRequest = processRequest mgr baseUrl
            , prepareWsRequest = processWsRequest baseUrl
            }

      return $ Just app'

processRequest :: Manager -> String
               -> (Options -> String -> IO (Response LB.ByteString))
               -> Options -> String -> IO (Response LB.ByteString)
processRequest mgr root req opts uri = do
  let opts' = opts & manager .~ Right mgr
      url = root ++ uri

  req opts' url


processWsRequest :: String -> (String -> Int -> IO ()) -> IO ()
processWsRequest baseUrl next = next (uriRegName auth) (read . drop 1 $ uriPort auth)
  where Just uri = parseURI baseUrl
        Just auth = uriAuthority uri

application :: Provider -> ScottyM ()
application provider = do
  middleware $ cors (const $ Just policy)

  get     matchAny . requireApp provider $ verifySignature' proxyGETHandler
  post    matchAny . requireApp provider $ verifySignature proxyPOSTHandler
  put     matchAny . requireApp provider $ verifySignature proxyPUTHandler
  delete  matchAny . requireApp provider $ verifySignature proxyDELETEHandler
  options matchAny optionsHandler

  where policy = simpleCorsResourcePolicy
                   { corsMethods = [ "GET", "POST", "PUT", "DELETE", "OPTIONS" ]
                   , corsRequestHeaders = [ "X-REQUEST-KEY"
                                          , "X-REQUEST-SIGNATURE"
                                          , "X-REQUEST-TIME"
                                          , "X-REQUEST-TYPE"
                                          , "X-REQUEST-NONCE"
                                          , "Content-Type"
                                          ]
                   , corsMaxAge = Just 86400
                   }
