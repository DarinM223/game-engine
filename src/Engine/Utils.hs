{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
module Engine.Utils
  ( errorString
  , perspectiveMat
  , loadShader
  , loadTexture
  , loadTexturePack
  , loadFont
  , linkShaders
  , loadVAO
  , loadVAOWithIndices
  , loadObj
  , shaderHeader
  ) where

import Codec.Picture
import Control.Exception (throwIO)
import Control.Monad (when)
import Control.Monad.IO.Class (MonadIO (liftIO))
import Data.Char (ord)
import Data.Foldable (for_, traverse_)
import Data.Function ((&))
import Data.Void (Void)
import Engine.Types
import Foreign.Marshal.Alloc (alloca)
import Foreign.Marshal.Array (allocaArray, peekArray)
import Foreign.Marshal.Utils (with)
import Foreign.Ptr (castPtr, nullPtr, plusPtr)
import Foreign.Storable (Storable (..), peek, sizeOf)
import Graphics.GL.Core45
import Graphics.GL.Types
import System.IO (IOMode (ReadMode), withFile)
import Text.Megaparsec (Parsec, empty, errorBundlePretty, runParser)
import Text.Megaparsec.Byte (char, space1, string)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Unsafe as BS
import qualified Data.Vector.Storable as V
import qualified Data.Vector.Storable.Mutable as VM
import qualified Linear
import qualified Streamly.External.ByteString as SBS
import qualified Streamly.FileSystem.Handle as SF
import qualified Streamly.Internal.Data.Fold as FL
import qualified Streamly.Internal.Memory.Array as A
import qualified Streamly.Prelude as S
import qualified Text.Megaparsec.Byte.Lexer as L

perspectiveMat :: Int -> Int -> Linear.M44 GLfloat
perspectiveMat width height =
  Linear.perspective fov aspectRatio nearPlane farPlane
 where
  fov = 45 * (pi / 180)
  aspectRatio = fromIntegral width / fromIntegral height
  nearPlane = 0.1
  farPlane = 1000

loadVAO :: V.Vector GLfloat -> Int -> IO RawModel
loadVAO v n = V.unsafeWith v $ \vPtr -> do
  vao <- alloca $ \vaoPtr -> do
    glGenVertexArrays 1 vaoPtr
    peek vaoPtr
  glBindVertexArray vao
  vbo <- alloca $ \vboPtr -> do
    glGenBuffers 1 vboPtr
    peek vboPtr
  glBindBuffer GL_ARRAY_BUFFER vbo
  glBufferData GL_ARRAY_BUFFER vSize (castPtr vPtr) GL_STATIC_DRAW

  glVertexAttribPointer 0 (fromIntegral n) GL_FLOAT GL_FALSE stride nullPtr
  glEnableVertexAttribArray 0

  glBindBuffer GL_ARRAY_BUFFER 0
  glBindVertexArray 0
  return RawModel { modelVao         = vao
                  , modelVertexCount = fromIntegral $ V.length v `quot` n
                  }
 where
  vSize = fromIntegral $ sizeOf (undefined :: GLfloat) * V.length v
  stride = fromIntegral $ sizeOf (undefined :: GLfloat) * n

loadVAOWithIndices :: V.Vector GLfloat -- ^ Positions
                   -> V.Vector GLuint  -- ^ Indices
                   -> IO RawModel
loadVAOWithIndices v e = V.unsafeWith v $ \vPtr ->
                         V.unsafeWith e $ \ePtr -> do
  vao <- alloca $ \vaoPtr -> do
    glGenVertexArrays 1 vaoPtr
    peek vaoPtr
  glBindVertexArray vao

  vbo <- alloca $ \vboPtr -> do
    glGenBuffers 1 vboPtr
    peek vboPtr
  glBindBuffer GL_ARRAY_BUFFER vbo
  glBufferData GL_ARRAY_BUFFER vSize (castPtr vPtr) GL_STATIC_DRAW

  ebo <- alloca $ \eboPtr -> do
    glGenBuffers 1 eboPtr
    peek eboPtr
  glBindBuffer GL_ELEMENT_ARRAY_BUFFER ebo
  glBufferData GL_ELEMENT_ARRAY_BUFFER eSize (castPtr ePtr) GL_STATIC_DRAW

  glVertexAttribPointer
    0        -- Attribute number to set
    3        -- Size of each vertex
    GL_FLOAT -- Data is type float
    GL_FALSE -- Not normalized (False)
    stride   -- Distance between each vertex
    nullPtr  -- Offset for first vertex
  glEnableVertexAttribArray 0

  glVertexAttribPointer
    1
    2
    GL_FLOAT
    GL_FALSE
    stride
    (nullPtr `plusPtr` (3 * sizeOf (undefined :: GLfloat)))
  glEnableVertexAttribArray 1

  glBindBuffer GL_ARRAY_BUFFER 0
  glBindVertexArray 0

  return RawModel { modelVao         = vao
                  , modelVertexCount = fromIntegral $ V.length e
                  }
 where
  vSize = fromIntegral $ sizeOf (undefined :: GLfloat) * V.length v
  eSize = fromIntegral $ sizeOf (undefined :: GLuint) * V.length e
  stride = fromIntegral $ sizeOf (undefined :: GLfloat) * 5

loadObj :: FilePath -> IO RawModel
loadObj path = do
  (vs, vts, vns, fs) <- withFile path ReadMode $ \handle ->
    S.unfold SF.read handle
      & S.splitOn (== 10) A.write
      & S.fold ((,,,) <$> foldV <*> foldVt <*> foldVn <*> foldF)
  vec <- liftIO $ VM.new (A.length fs * 24)
  S.unfold A.read fs
    & S.foldlM' (writeVec vs vts vns vec) (0 :: Int)
    & S.drain
  toRawModel vec
 where
  writeVec vs vts vns vec i f = liftIO $ do
    writeVertex i (fA f) vec vs vts vns
    writeVertex (i + 8) (fB f) vec vs vts vns
    writeVertex (i + 16) (fC f) vec vs vts vns
    return (i + 24)
  writeVertex i (ThreeTuple a b c) vec vs vts vns = do
    for_ (A.readIndex vs (a - 1)) $ \v -> do
      VM.write vec i (threeDX v)
      VM.write vec (i + 1) (threeDY v)
      VM.write vec (i + 2) (threeDZ v)
    for_ (A.readIndex vts (b - 1)) $ \vt -> do
      VM.write vec (i + 3) (twoDX vt)
      VM.write vec (i + 4) (twoDY vt)
    for_ (A.readIndex vns (c - 1)) $ \vn -> do
      VM.write vec (i + 5) (threeDX vn)
      VM.write vec (i + 6) (threeDY vn)
      VM.write vec (i + 7) (threeDZ vn)

  isC c arr = A.readIndex arr 0 == Just (fromIntegral (ord c))
           && A.readIndex arr 1 == Just (fromIntegral (ord ' '))
  isVC c arr = A.readIndex arr 0 == Just (fromIntegral (ord 'v'))
            && A.readIndex arr 1 == Just (fromIntegral (ord c))

  sc = L.space space1 empty empty

  parse2d :: BS.ByteString -> Parsec Void BS.ByteString TwoDPoint
  parse2d s = TwoDPoint
          <$> (string s *> sc *> L.signed sc L.float <* sc)
          <*> L.signed sc L.float
  parse3d s = ThreeDPoint
          <$> (string s *> sc *> L.signed sc L.float <* sc)
          <*> (L.signed sc L.float <* sc)
          <*> L.signed sc L.float
  parseSlashes = ThreeTuple
    <$> (L.decimal <* char slash) <*> (L.decimal <* char slash) <*> L.decimal
   where slash = fromIntegral $ ord '/'
  parseFragment = FData
              <$> (char (fromIntegral (ord 'f')) *> sc *> parseSlashes)
              <*> (sc *> parseSlashes <* sc)
              <*> parseSlashes

  runPointParser p arr = case runParser p "" (SBS.fromArray arr) of
    Left err -> error $ errorBundlePretty err
    Right v  -> v
  parseV arr = runPointParser (parse3d "v") arr
  parseVn arr = runPointParser (parse3d "vn") arr
  parseVt arr = runPointParser (parse2d "vt") arr

  foldV = FL.lfilter (isC 'v') (FL.lmap parseV A.write)
  foldVt = FL.lfilter (isVC 't') (FL.lmap parseVt A.write)
  foldVn = FL.lfilter (isVC 'n') (FL.lmap parseVn A.write)
  foldF = FL.lfilter (isC 'f') (FL.lmap (runPointParser parseFragment) A.write)

  toRawModel v = VM.unsafeWith v $ \vPtr -> do
    vao <- alloca $ \vaoPtr -> do
      glGenVertexArrays 1 vaoPtr
      peek vaoPtr
    glBindVertexArray vao

    vbo <- alloca $ \vboPtr -> do
      glGenBuffers 1 vboPtr
      peek vboPtr
    glBindBuffer GL_ARRAY_BUFFER vbo
    glBufferData GL_ARRAY_BUFFER vSize (castPtr vPtr) GL_STATIC_DRAW

    glVertexAttribPointer 0 3 GL_FLOAT GL_FALSE stride nullPtr
    glEnableVertexAttribArray 0

    glVertexAttribPointer 1 2 GL_FLOAT GL_FALSE stride
      (nullPtr `plusPtr` (3 * sizeOf (undefined :: GLfloat)))
    glEnableVertexAttribArray 1

    glVertexAttribPointer 2 3 GL_FLOAT GL_FALSE stride
      (nullPtr `plusPtr` (5 * sizeOf (undefined :: GLfloat)))
    glEnableVertexAttribArray 2

    glBindBuffer GL_ARRAY_BUFFER 0
    glBindVertexArray 0
    return RawModel { modelVao         = vao
                    , modelVertexCount = fromIntegral $ VM.length v `quot` 8
                    }
   where
    vSize = fromIntegral $ sizeOf (undefined :: GLfloat) * VM.length v
    stride = fromIntegral $ sizeOf (undefined :: GLfloat) * 8

parseCharacter :: BS.ByteString -> Character
parseCharacter s = case runParser parse' "" s of
  Left err -> error $ errorBundlePretty err
  Right v  -> v
 where
  sc = L.space space1 empty empty
  parse' :: Parsec Void BS.ByteString Character
  parse' = Character
       <$> (string "char id=" *> L.decimal <* sc)
       <*> (string "x=" *> L.signed sc L.decimal <* sc)
       <*> (string "y=" *> L.signed sc L.decimal <* sc)
       <*> (string "width=" *> L.signed sc L.decimal <* sc)
       <*> (string "height=" *> L.signed sc L.decimal <* sc)
       <*> (string "xoffset=" *> L.signed sc L.decimal <* sc)
       <*> (string "yoffset=" *> L.signed sc L.decimal <* sc)
       <*> (string "xadvance=" *> L.signed sc L.decimal <* sc)

loadFont :: FilePath -> IO (VM.IOVector Character)
loadFont path = do
  chars <- VM.new 256
  withFile path ReadMode $ \handle ->
    S.unfold SF.read handle
      & S.splitOn (== 10) SBS.write
      & S.drop 4
      & S.filter ((> 0) . BS.length)
      & S.map parseCharacter
      & S.mapM_ (\ch -> VM.write chars (charId ch) ch)
  return chars

loadTexture :: FilePath -> IO Texture
loadTexture path = do
  Right file <- readImage path
  let ipixelrgb8 = convertRGBA8 file
      iWidth     = fromIntegral $ imageWidth ipixelrgb8
      iHeight    = fromIntegral $ imageHeight ipixelrgb8
      iData      = imageData ipixelrgb8
  texture <- alloca $ \texturePtr -> do
    glGenTextures 1 texturePtr
    peek texturePtr
  glBindTexture GL_TEXTURE_2D texture

  glGenerateMipmap GL_TEXTURE_2D
  glTexParameteri GL_TEXTURE_2D GL_TEXTURE_WRAP_S GL_REPEAT
  glTexParameteri GL_TEXTURE_2D GL_TEXTURE_WRAP_T GL_REPEAT
  glTexParameteri GL_TEXTURE_2D GL_TEXTURE_MIN_FILTER GL_LINEAR_MIPMAP_LINEAR
  glTexParameteri GL_TEXTURE_2D GL_TEXTURE_MAG_FILTER GL_LINEAR
  glTexParameterf GL_TEXTURE_2D GL_TEXTURE_LOD_BIAS (-0.4)

  V.unsafeWith iData $ \dataPtr ->
    glTexImage2D
      GL_TEXTURE_2D
      0
      GL_RGBA
      iWidth
      iHeight
      0
      GL_RGBA
      GL_UNSIGNED_BYTE
      (castPtr dataPtr)
  glGenerateMipmap GL_TEXTURE_2D
  glBindTexture GL_TEXTURE_2D 0
  return $ Texture texture 1.0 0.0 0 0 1

loadTexturePack
  :: FilePath -> FilePath -> FilePath -> FilePath -> IO TexturePack
loadTexturePack back r g b = TexturePack
  <$> loadTexture back <*> loadTexture r <*> loadTexture g <*> loadTexture b

infoLength :: Int
infoLength = 512

loadShader :: GLenum -> BS.ByteString -> IO GLuint
loadShader shaderType bs = do
  shader <- glCreateShader shaderType
  BS.unsafeUseAsCStringLen bs $ \(bsPtr, len) ->
    with bsPtr $ \ptrPtr ->
    with (fromIntegral len) $ \lenPtr ->
      glShaderSource shader 1 ptrPtr lenPtr >>
      glCompileShader shader
  vertexSuccess <- alloca $ \vertexSuccessPtr -> do
    glGetShaderiv shader GL_COMPILE_STATUS vertexSuccessPtr
    peek vertexSuccessPtr
  when (vertexSuccess == GL_FALSE) $
    alloca $ \resultPtr ->
    allocaArray infoLength $ \infoLog -> do
      glGetShaderInfoLog shader (fromIntegral infoLength) resultPtr infoLog
      logLength <- peek resultPtr
      logBytes <- peekArray (fromIntegral logLength) infoLog
      throwIO $ ShaderException $ fmap (toEnum . fromEnum) logBytes
  return shader

linkShaders :: [GLuint] -> IO GLuint
linkShaders shaders = do
  program <- glCreateProgram
  traverse_ (glAttachShader program) shaders
  glLinkProgram program
  linkSuccess <- alloca $ \linkSuccessPtr -> do
    glGetProgramiv program GL_LINK_STATUS linkSuccessPtr
    peek linkSuccessPtr
  when (linkSuccess == GL_FALSE) $
    alloca $ \resultPtr ->
    allocaArray infoLength $ \infoLog -> do
      glGetProgramInfoLog program (fromIntegral infoLength) resultPtr infoLog
      logLength <- peek resultPtr
      logBytes <- peekArray (fromIntegral logLength) infoLog
      throwIO $ LinkException $ fmap (toEnum . fromEnum) logBytes
  return program

shaderHeader :: Int -> String
shaderHeader maxLights =
  "#version 330 core\n" ++ "#define NUM_LIGHTS " ++ show maxLights ++ "\n"

errorString :: GLenum -> String
errorString GL_NO_ERROR                      = "No error"
errorString GL_INVALID_ENUM                  = "Invalid enum"
errorString GL_INVALID_VALUE                 = "Invalid value"
errorString GL_INVALID_OPERATION             = "Invalid operation"
errorString GL_STACK_OVERFLOW                = "Stack overflow"
errorString GL_STACK_UNDERFLOW               = "Stack underflow"
errorString GL_OUT_OF_MEMORY                 = "Out of memory"
errorString GL_INVALID_FRAMEBUFFER_OPERATION = "Invalid framebuffer operation"
errorString _                                = "Unknown error"
