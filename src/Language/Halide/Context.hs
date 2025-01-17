{-# LANGUAGE TemplateHaskellQuotes #-}

-- |
-- Module      : Language.Halide.Context
-- Description : Helpers to setup inline-c context for Halide
-- Copyright   : (c) Tom Westerhout, 2023
module Language.Halide.Context
  ( importHalide
  , handleHalideExceptions
  , handleHalideExceptionsM
  )
where

import Data.Text (unpack)
import Data.Text.Encoding (decodeUtf8)
import GHC.Stack (HasCallStack)
import qualified Language.C.Inline as C
import qualified Language.C.Inline.Cpp as C
import qualified Language.C.Inline.Cpp.Exception as C
import Language.Halide.Buffer
import Language.Halide.Type
import Language.Haskell.TH (DecsQ)

-- | One stop function to include all the neccessary machinery to call Halide
-- functions via inline-c.
importHalide :: DecsQ
importHalide =
  concat
    <$> sequence
      [ C.context halideCxt
      , C.include "<Halide.h>"
      , defineExceptionHandler
      ]

-- | Convert Halide C++ exceptions into calls to 'error'.
--
-- Normally, you would use it like this:
--
-- > halideHandleExceptions
-- >   =<< [C.tryBlock| void {
-- >         handle_halide_exceptions([=]() {
-- >           Halide::Func f;
-- >           f() = *$(Halide::Expr* e);
-- >           f.realize(Halide::Pipeline::RealizationArg{$(halide_buffer_t* b)});
-- >         });
-- >       } |]
handleHalideExceptions :: HasCallStack => Either C.CppException a -> IO a
handleHalideExceptions (Right x) = pure x
handleHalideExceptions (Left (C.CppStdException _ msg _)) = error $ unpack (decodeUtf8 msg)
handleHalideExceptions (Left err) = error $ "Halide error: " <> show err

-- | Similar to 'handleHalideExceptions' but takes a monadic action.
handleHalideExceptionsM :: HasCallStack => IO (Either C.CppException a) -> IO a
handleHalideExceptionsM action = action >>= handleHalideExceptions

-- | Define @inline-c@ context for Halide types.
halideCxt :: C.Context
halideCxt =
  C.cppCtx
    <> C.fptrCtx
    <> C.bsCtx
    <> C.cppTypePairs
      [ ("Halide::Expr", [t|CxxExpr|])
      , ("Halide::Var", [t|CxxVar|])
      , ("Halide::RVar", [t|CxxRVar|])
      , ("Halide::VarOrRVar", [t|CxxVarOrRVar|])
      , ("Halide::Func", [t|CxxFunc|])
      , ("Halide::Internal::Parameter", [t|CxxParameter|])
      , ("Halide::ImageParam", [t|CxxImageParam|])
      , ("Halide::Callable", [t|CxxCallable|])
      , ("Halide::Target", [t|CxxTarget|])
      , ("Halide::JITUserContext", [t|CxxUserContext|])
      , ("Halide::Argument", [t|CxxArgument|])
      , ("std::vector", [t|CxxVector|])
      , ("halide_buffer_t", [t|RawHalideBuffer|])
      , ("halide_type_t", [t|HalideType|])
      ]

-- | Define a C++ function @halide_handle_exception@ that converts Halide
-- exceptions into @std::runtime_error@. It can be used inside 'C.tryBlock' or
-- 'C.catchBlock' to properly re-throw Halide errors (otherwise we'll get a
-- call to @std::terminate@).
--
-- E.g.
--
--    [C.catchBlock| void {
--      handle_halide_exceptions([=]() {
--        Halide::Func f;
--        Halide::Var i;
--        f(i) = *$(Halide::Expr* e);
--        f.realize(Halide::Pipeline::RealizationArg{$(halide_buffer_t* b)});
--      });
--    } |]
defineExceptionHandler :: DecsQ
defineExceptionHandler =
  C.verbatim
    "\
    \class ErrorContext { \n\
    \  bool has_error;\n\
    \  std::string msg;\n\
    \\n\
    \public:                                                      \n\
    \  ErrorContext() noexcept : has_error{false}, msg{} {}\n\
    \                                                              \n\
    \  constexpr auto hasError() const noexcept -> bool { return has_error; }\n\
    \  auto error() const noexcept -> char const* { return msg.c_str(); }\n\
    \  auto error(char const* s) { has_error = true; msg = std::string{s}; }\n\
    \  auto reset() noexcept { has_error = false; msg.clear(); }\n\
    \};\n\
    \\n\
    \inline auto& get_error_context() { \n\
    \  static thread_local ErrorContext ctx; \n\
    \  return ctx; \n\
    \}\n\
    \\n\
    \template <class Func>                               \n\
    \auto catch_exceptions(Func&& func) noexcept -> bool {       \n\
    \  try {                                             \n\
    \    func();                                  \n\
    \    return false;\n\
    \  } catch(Halide::RuntimeError& e) {                \n\
    \    get_error_context().error(e.what());             \n\
    \  } catch(Halide::CompileError& e) {                \n\
    \    fprintf(stderr, \"Caught CompileError: %s\\n\", e.what()); \n\
    \    get_error_context().error(e.what());             \n\
    \  } catch(Halide::InternalError& e) {               \n\
    \    get_error_context().error(e.what());             \n\
    \  } catch(Halide::Error& e) {                       \n\
    \    get_error_context().error(e.what());             \n\
    \  } catch(std::exception& e) {                       \n\
    \    get_error_context().error(e.what());             \n\
    \  } catch(...) {                       \n\
    \    get_error_context().error(\"unknown exception\");             \n\
    \  }                                                 \n\
    \  fprintf(stderr, \"Returning true...\\n\"); \n\
    \  return true;                                      \n\
    \}                                                   \n\
    \\n\
    \template <class Func>                               \n\
    \auto handle_halide_exceptions(Func&& func) {        \n\
    \  try {                                             \n\
    \    return func();                                  \n\
    \  } catch(Halide::RuntimeError& e) {                \n\
    \    throw std::runtime_error{e.what()};             \n\
    \  } catch(Halide::CompileError& e) {                \n\
    \    throw std::runtime_error{e.what()};             \n\
    \  } catch(Halide::InternalError& e) {               \n\
    \    throw std::runtime_error{e.what()};             \n\
    \  } catch(Halide::Error& e) {                       \n\
    \    throw std::runtime_error{e.what()};             \n\
    \  }                                                 \n\
    \}                                                   \n\
    \"