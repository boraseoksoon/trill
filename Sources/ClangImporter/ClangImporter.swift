///
/// ClangImporter.swift
///
/// Copyright 2016-2017 the Trill project authors.
/// Licensed under the MIT License.
///
/// Full license text available at https://github.com/trill-lang/trill
///

import AST
import cclang
import Clang
import Foundation
import LLVMWrappers
import Parse
import Runtime
import Source

extension CXErrorCode: Error, CustomStringConvertible {
  public var description: String {
    switch self {
    case CXError_Success:
      return "CXErrorCode.success"
    case CXError_Crashed:
      return "CXErrorCode.crashed"
    case CXError_Failure:
      return "CXErrorCode.failure"
    case CXError_ASTReadError:
      return "CXErrorCode.astReadError"
    case CXError_InvalidArguments:
      return "CXErrorCode.invalidArguments"
    default:
      fatalError("unknown CXErrorCode: \(self.rawValue)")
    }
  }
}

enum ImportError: Error {
  case pastInt64
}

extension CXCursor {
  var isInvalid: Bool {
    switch self.kind {
    case CXCursor_InvalidCode: return true
    case CXCursor_InvalidFile: return true
    case CXCursor_LastInvalid: return true
    case CXCursor_FirstInvalid: return true
    case CXCursor_NotImplemented: return true
    case CXCursor_NoDeclFound: return true
    default: return false
    }
  }
  var isValid: Bool { return !self.isInvalid }
}

extension CXString {
  func asSwift() -> String {
    guard self.data != nil else { return "<none>" }
    defer { clang_disposeString(self) }
    return String(cString: clang_getCString(self))
  }
}

extension String {
  var lastWord: String? {
    return components(separatedBy: " ").last
  }
}

public final class ClangImporter: Pass {
  static let headerFiles = [
    "stdlib.h",
    "stdio.h",
    "fcntl.h",
    "stdint.h",
    "stddef.h",
    "math.h",
    "string.h",
    "_types.h",
    "pthread.h",
    "sys/time.h",
    "sys/resource.h",
    "sched.h",
  ]
  #if os(macOS)
  static func loadSDKPath() -> String? {
    let pipe = Pipe()
    let xcrun = Process()
    xcrun.launchPath = "/usr/bin/xcrun"
    xcrun.arguments = ["--show-sdk-path", "--sdk", "macosx"]
    xcrun.standardOutput = pipe
    xcrun.launch()
    xcrun.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static let sdkPath: String? = loadSDKPath()
  static let includeDir = sdkPath.map { $0 + "/usr/include" }
  #else
  static let includeDir: String? = "/usr/local/include"
  #endif

  public let context: ASTContext
  let targetTriple: String
  let runtimeLocation: RuntimeLocation

  var importedTypes = [Identifier: TypeDecl]()
  var importedFunctions = [Identifier: FuncDecl]()

  required public init(context: ASTContext) {
    fatalError("use init(context:target:)")
  }

  public init(context: ASTContext, target: String,
              runtimeLocation: RuntimeLocation) {
    self.context = context
    self.targetTriple = target
    self.runtimeLocation = runtimeLocation
  }

  public var title: String {
    return "Clang Importer"
  }

  func translationUnit(for path: String) throws -> CXTranslationUnit {
    let index = clang_createIndex(1, 1)
    var args = [
      "-I", runtimeLocation.includeDir.path,
      "-std=gnu11", "-fsyntax-only",
      "-target", targetTriple
    ]
    #if os(macOS)
      if let sdkPath = ClangImporter.sdkPath {
        args.append("-isysroot")
        args.append(sdkPath)
      }
    #endif
    defer {
      clang_disposeIndex(index)
    }

    let flags = [
      CXTranslationUnit_SkipFunctionBodies,
      CXTranslationUnit_DetailedPreprocessingRecord
    ].reduce(0 as UInt32) { $0 | $1.rawValue }

    return try args.withCArrayOfCStrings { ptr in
      var tu: CXTranslationUnit? = nil

      let err = clang_parseTranslationUnit2(index,
                                            path,
                                            ptr, Int32(args.count), nil,
                                            0, flags, &tu)
      guard err == CXError_Success else {
        throw err
      }
      guard let _tu = tu else {
        throw CXError_Failure
      }
      return _tu
    }
  }

  func synthesize(name: String, args: [DataType],
                  return: DataType,
                  hasVarArgs: Bool,
                  modifiers: [DeclModifier],
                  range: Source.SourceRange?,
                  argRanges: [Source.SourceRange] = []) -> FuncDecl {
    let params = args.enumerated().map { arg -> ParamDecl in
      let range = argRanges[safe: arg.0]
      let ref = arg.1.ref(range: range)
      return ParamDecl(name: "", type: ref, sourceRange: range)
    }
    return FuncDecl(name: Identifier(name: name),
                        returnType: `return`.ref(),
                        args: params,
                        modifiers: modifiers,
                        hasVarArgs: hasVarArgs,
                        sourceRange: range)
  }

  @discardableResult
  func importTypeDef(_ cursor: CXCursor, in context: ASTContext) -> AST.TypeAliasDecl? {
    let name = clang_getCursorSpelling(cursor).asSwift()
    guard ClangImporter.builtinTypeReplacements[name] == nil else { return nil }
    let type = clang_getTypedefDeclUnderlyingType(cursor)
    let decl = clang_getTypeDeclaration(type)
    var trillType: DataType?
    if decl.kind == CXCursor_StructDecl {
      if let expr = importStruct(decl, in: context) {
        trillType = expr.type
      } else {
        return nil
      }
    } else {
      trillType = convertToTrillType(type)
    }
    guard let t = trillType else {
      return nil
    }

    // If we see a struct declared as:
    //
    // typedef struct struct_name {
    // } struct_name;
    //
    // Where the typedef renames the type without the `struct` keyword, then
    // skip creating a TypeAliasDecl for that type, as it would be circular.
    if t.description == name, context.decl(for: t) != nil {
      return nil
    }

    let range = makeRange(clang_getCursorExtent(cursor))
    let alias = TypeAliasDecl(name: Identifier(name: name),
                              bound: t.ref(range: range),
                              sourceRange: range)
    context.add(alias)
    return alias
  }

  @discardableResult
  func importStruct(_ cursor: CXCursor, in context: ASTContext) -> TypeDecl? {
    let type = clang_getCursorType(cursor)
    guard let typeName = clang_getTypeSpelling(type).asSwift().lastWord else {
        return nil
    }
    let name = Identifier(name: typeName)

    if let e = importedTypes[name] { return e }

    var values = [PropertyDecl]()

    var childIdx = 0
    let res = clang_visitChildrenWithBlock(cursor) { child, parent in
      defer { childIdx += 1 }
      var fieldName = clang_getCursorSpelling(child).asSwift()
      if fieldName.isEmpty {
        fieldName = "__unnamed_\(childIdx)"
      }
      let fieldId = Identifier(name: fieldName,
                               range: nil)
      let fieldTy = clang_getCursorType(child)
      guard let trillTy = self.convertToTrillType(fieldTy) else {
        return CXChildVisit_Break
      }
      let range = self.makeRange(clang_getCursorExtent(child))
      let expr = PropertyDecl(name: fieldId,
                              type: trillTy.ref(),
                              mutable: true,
                              rhs: nil,
                              modifiers: [.foreign, .implicit],
                              getter: nil,
                              setter: nil,
                              sourceRange: range)
      values.append(expr)
      return CXChildVisit_Continue
    }
    guard res == 0 else {
      return nil
    }

    let range = makeRange(clang_getCursorExtent(cursor))
    let expr = TypeDecl(name: name, properties: values, modifiers: [.foreign, .implicit],
                        sourceRange: range)
    importedTypes[name] = expr
    context.add(expr)
    return expr
  }

  func importFunction(_ cursor: CXCursor, in context: ASTContext)  {
    var cursor = cursor
    let name = clang_getCursorSpelling(cursor).asSwift()
    if importedFunctions[Identifier(name: name)] != nil { return }
    let numArgs = clang_Cursor_getNumArguments(cursor)
    guard numArgs != -1 else { return }
    var modifiers = [DeclModifier.foreign, DeclModifier.implicit]
    if clang_isNoReturn(&cursor) != 0 {
      modifiers.append(.noreturn)
    }
    let hasVarArgs = clang_Cursor_isVariadic(cursor) != 0
    let funcType = clang_getCursorType(cursor)
    let returnTy = clang_getResultType(funcType)

    guard let trillRetTy = convertToTrillType(returnTy) else { return }

    var args = [DataType]()
    var argRanges = [Source.SourceRange]()
    for i in 0..<numArgs {
      let type = clang_getArgType(funcType, UInt32(i))
      let range = clang_getCursorExtent(clang_Cursor_getArgument(cursor, UInt32(i)))

      guard let trillType = convertToTrillType(type) else { return }
      args.append(trillType)
      argRanges.append(makeRange(range))
    }

    let range = makeRange(clang_getCursorExtent(cursor))
    let decl = synthesize(name: name,
                          args: args,
                          return: trillRetTy,
                          hasVarArgs: hasVarArgs,
                          modifiers: modifiers,
                          range: range,
                          argRanges: argRanges)
    importedFunctions[decl.name] = decl
    context.add(decl)
  }

  func importEnum(_ cursor: CXCursor, in context: ASTContext) {
    clang_visitChildrenWithBlock(cursor) { child, parent in
      let name = Identifier(name: clang_getCursorSpelling(child).asSwift())
      if context.global(named: name) != nil { return CXChildVisit_Continue }

      let range = self.makeRange(clang_getCursorExtent(child))
      let varExpr = VarAssignDecl(name: name,
                                  typeRef: DataType.int32.ref(),
                                  modifiers: [.foreign, .implicit],
                                  mutable: false,
                                  sourceRange: range)!
      context.add(varExpr)
      return CXChildVisit_Continue
    }
  }

  func importUnion(_ cursor: CXCursor, context: ASTContext) {
    let type = clang_getCursorType(cursor)
    guard let typeName = clang_getTypeSpelling(type).asSwift().lastWord else {
      return
    }
    var maxType: (CXType, Int)? = nil
    clang_visitChildrenWithBlock(cursor) { child, parent in
      let fieldType = clang_getCursorType(child)
      let fieldSize = Int(clang_Type_getSizeOf(fieldType))
      guard let max = maxType else {
        maxType = (fieldType, fieldSize)
        return CXChildVisit_Continue
      }
      if fieldSize > max.1 {
        maxType = (fieldType, fieldSize)
      }
      return CXChildVisit_Continue
    }
    guard let max = maxType?.0,
      let trillType = convertToTrillType(max) else {
      return
    }
    let alias = makeAlias(name: typeName, type: trillType)
    context.add(alias)
  }

  func importMacro(_ cursor: CXCursor, in tu: CXTranslationUnit, context: ASTContext) {
    if clang_Cursor_isMacroFunctionLike(cursor) != 0 { return }
    let range = clang_getCursorExtent(cursor)

    var tokenCount: UInt32 = 0
    var _tokens: UnsafeMutablePointer<CXToken>?
    clang_tokenize(tu, range, &_tokens, &tokenCount)

    guard let tokens = _tokens, tokenCount >= 2 else { return }

    defer {
      clang_disposeTokens(tu, tokens, tokenCount)
    }

    clang_annotateTokens(tu, tokens, tokenCount, nil)

    let name = clang_getTokenSpelling(tu, tokens[0]).asSwift()
    guard context.global(named: Identifier(name: name)) == nil else { return }
    switch clang_getTokenKind(tokens[1]) {
    case CXToken_Literal:
      guard let assign = parse(tu: tu, token: tokens[1], name: name) else { return }
      context.add(assign)
    case CXToken_Identifier:
      let identifierName = clang_getTokenSpelling(tu, tokens[1]).asSwift()
      guard let _ = context.global(named: identifierName) else { return }
      let rhs = VarExpr(name: Identifier(name: identifierName, range: makeRange(clang_getTokenExtent(tu, tokens[1]))))
      let varDecl = VarAssignDecl(name: Identifier(name: name),
                                  typeRef: nil,
                                  kind: .global,
                                  rhs: rhs,
                                  modifiers: [.implicit],
                                  mutable: false,
                                  sourceRange: makeRange(range))
      context.add(varDecl!)
    default:
      return
    }
  }

  func importVariableDeclation(_ cursor: CXCursor, in tu: CXTranslationUnit, context: ASTContext) {
    guard let type = convertToTrillType(clang_getCursorType(cursor)) else { return }
    let name = clang_getCursorSpelling(cursor).asSwift()
    let identifier = Identifier(name: name, range: makeRange(clang_getCursorExtent(cursor)))
    if let existing = context.global(named: name), existing.sourceRange == identifier.range { return }

    context.add(VarAssignDecl(name: identifier,
                              typeRef: type.ref(),
                              kind: .global,
                              rhs: nil,
                              modifiers: [.foreign, .implicit],
                              mutable: false,
                              sourceRange: identifier.range)!)
  }

  // FIXME: Actually use Clang's lexer instead of re-implementing parts of
  //        it, poorly.
  func simpleParseIntegerLiteralToken(_ rawToken: String) throws -> NumExpr? {
    var token = rawToken.lowercased()
    // HACK: harcoded UInt64.max
    if token == "18446744073709551615ul" || token == "18446744073709551615ull" {
      let expr = NumExpr(value: Int64(bitPattern: UInt64.max), raw: rawToken)
      expr.type = .uint64
      return expr
    }
    let suffixTypeMap: [(String, DataType)] = [
      ("ull", .uint64), ("ul", .uint64), ("ll", .int64),
      ("u", .uint32), ("l", .int64)
    ]

    var type = DataType.int64

    for (suffix, suffixType) in suffixTypeMap {
      if token.hasSuffix(suffix) {
        type = suffixType
        let suffixStartIndex = token.index(token.endIndex,
                                                      offsetBy: -suffix.count)
        token.removeSubrange(suffixStartIndex..<token.endIndex)
        break
      }
    }

    guard let num = token.asNumber() else { return nil }

    let expr = NumExpr(value: num, raw: rawToken)
    expr.type = type
    return expr
  }

  func simpleParseCToken(_ token: String, range: Source.SourceRange) throws -> Expr? {
    var lexer = Lexer(file: range.start.file, input: token)
    let toks = try lexer.lex()
    guard let first = toks.first?.kind else { return nil }
    switch first {
    case .char(let value):
      return CharExpr(value: value, sourceRange: range)
    case .stringLiteral(let value):
      let stringExpr = StringExpr(value: value, sourceRange: range)
      stringExpr.type = .pointer(type: .int8)
      return stringExpr
    case .number(let value, let raw):
      return NumExpr(value: value, raw: raw, sourceRange: range)
    case .identifier(let name):
      return try simpleParseIntegerLiteralToken(name) ?? VarExpr(name: Identifier(name: name, range: range), sourceRange: range)
    default:
      return nil
    }
  }

  func parse(tu: CXTranslationUnit, token: CXToken, name: String) -> VarAssignDecl? {
    do {
      let tok = clang_getTokenSpelling(tu, token).asSwift()
      let range = makeRange(clang_getTokenExtent(tu, token))
      guard let expr = try simpleParseCToken(tok, range: range) else { return nil }

      return VarAssignDecl(name: Identifier(name: name),
                           typeRef: expr.type.ref(),
                           rhs: expr,
                           modifiers: [.implicit],
                           mutable: false,
                           sourceRange: range)
    } catch { return nil }
  }

  func makeAlias(name: String, type: DataType, range: Source.SourceRange? = nil) -> AST.TypeAliasDecl {
    return TypeAliasDecl(name: Identifier(name: name),
                         bound: type.ref(),
                         modifiers: [.implicit],
                         sourceRange: range)
  }

  func importDeclarations(for path: String, in context: ASTContext) {
    do {
      let file = try SourceFile(path: .file(URL(fileURLWithPath: path)), sourceFileManager: context.sourceFileManager)
      context.add(file)
    } catch {
      // do nothing
    }
    let tu: CXTranslationUnit
    do {
      tu = try translationUnit(for: path)
    } catch {
      context.error(error)
      return
    }
    let cursor = clang_getTranslationUnitCursor(tu)
    clang_visitChildrenWithBlock(cursor) { child, parent in
      let kind = clang_getCursorKind(child)
      switch kind {
      case CXCursor_TypedefDecl:
        self.importTypeDef(child, in: context)
      case CXCursor_EnumDecl:
        self.importEnum(child, in: context)
      case CXCursor_StructDecl:
        self.importStruct(child, in: context)
      case CXCursor_FunctionDecl:
        self.importFunction(child, in: context)
      case CXCursor_MacroDefinition:
        self.importMacro(child, in: tu, context: context)
      case CXCursor_UnionDecl:
        self.importUnion(child, context: context)
      case CXCursor_VarDecl:
        self.importVariableDeclation(child, in: tu, context: context)
      default:
        break
      }
      return CXChildVisit_Continue
    }
    clang_disposeTranslationUnit(tu)
  }

  func importBuiltinAliases(into context: ASTContext) {
    context.add(makeAlias(name: "__builtin_va_list",
                          type: .pointer(type: .void)))
    context.add(makeAlias(name: "__va_list_tag",
                          type: .pointer(type: .void)))
  }

  func importBuiltinFunctions(into context: ASTContext) {
    func add(_ decl: FuncDecl) {
      context.add(decl)
      importedFunctions[decl.name] = decl
    }

    add(synthesize(name: "trill_fatalError",
                   args: [.pointer(type: .int8)],
                   return: .void,
                   hasVarArgs: false,
                   modifiers: [.foreign, .noreturn],
                   range: nil))

    // calloc and realloc is imported with `int` for their arguments.
    // I need to override them with .int64 for their arguments.
    add(synthesize(name: "malloc",
                   args: [.int64],
                   return: .pointer(type: .void),
                   hasVarArgs: false,
                   modifiers: [.foreign],
                   range: nil))
    add(synthesize(name: "calloc",
                   args: [.int64, .int64],
                   return: .pointer(type: .void),
                   hasVarArgs: false,
                   modifiers: [.foreign],
                   range: nil))
    add(synthesize(name: "realloc",
                   args: [.pointer(type: .void), .int64],
                   return: .pointer(type: .void),
                   hasVarArgs: false,
                   modifiers: [.foreign],
                   range: nil))
  }

  public func run(in context: ASTContext) {
    importBuiltinAliases(into: context)
    importBuiltinFunctions(into: context)
    importDeclarations(for: runtimeLocation.header.path,
                       in: context)
    if let path = ClangImporter.includeDir {
      for header in ClangImporter.headerFiles {
        importDeclarations(for: "\(path)/\(header)", in: context)
      }
    }
  }

  static let builtinTypeReplacements: [String: DataType] = [
    "size_t": .int64,
    "ssize_t": .int64,
    "rsize_t": .int64,
    "uint64_t": .uint64,
    "uint32_t": .uint32,
    "uint16_t": .uint16,
    "uint8_t": .uint8,
    "int64_t": .int64,
    "int32_t": .int32,
    "int16_t": .int16,
    "int8_t": .int8,
    "TRILL_ANY": .any,
  ]

  func convertToTrillType(_ type: CXType) -> DataType? {
    switch type.kind {
    case CXType_Void: return .void
    case CXType_Int: return .int32
    case CXType_Bool: return .bool
    case CXType_Enum: return .int32
    case CXType_Float: return .float
    case CXType_Double: return .double
    case CXType_LongDouble: return .float80
    case CXType_Long: return .int64
    case CXType_UInt: return .uint32
    case CXType_LongLong: return .int64
    case CXType_ULong: return .uint64
    case CXType_ULongLong: return .uint64
    case CXType_Short: return .int16
    case CXType_UShort: return .uint16
    case CXType_SChar: return .int8
    case CXType_Char_S: return .int8
    case CXType_Char16: return .int16
    case CXType_Char32: return .int32
    case CXType_UChar: return .uint8
    case CXType_WChar: return .int16
    case CXType_ObjCSel: return .pointer(type: .int8)
    case CXType_ObjCId: return .pointer(type: .int8)
    case CXType_NullPtr: return .pointer(type: .int8)
    case CXType_Unexposed: return .pointer(type: .int8)
    case CXType_ConstantArray:
      let underlying = clang_getArrayElementType(type)
      guard let trillTy = convertToTrillType(underlying) else { return nil }
      return .pointer(type: trillTy)
    case CXType_Pointer:
      let pointee = clang_getPointeeType(type)
      // Check to see if the pointee is a function type:
      if clang_getResultType(pointee).kind != CXType_Invalid {
        // function pointer type.
        guard let t = convertFunctionType(pointee) else { return nil }
        return t
      }
      let trillPointee = convertToTrillType(pointee)
      guard let p = trillPointee else {
        return nil
      }
      return .pointer(type: p)
    case CXType_FunctionProto:
      return convertFunctionType(type)
    case CXType_FunctionNoProto:
      let ret = clang_getResultType(type)
      guard let trillRet = convertToTrillType(ret) else { return nil }
      return .function(args: [], returnType: trillRet, hasVarArgs: false)
    case CXType_Typedef:
      let typeDecl = clang_getTypeDeclaration(type)
      let typeName = clang_getCursorSpelling(typeDecl).asSwift()
      if let replacement = ClangImporter.builtinTypeReplacements[typeName] {
        return replacement
      }
      return DataType(name: typeName)
    case CXType_Record:
      guard let name = clang_getTypeSpelling(type).asSwift().lastWord else {
          return nil
      }
      return DataType(name: name)
    case CXType_ConstantArray:
      let element = clang_getArrayElementType(type)
      let size = clang_getNumArgTypes(type)
      guard let trillElType = convertToTrillType(element) else { return nil }
      return .tuple(fields: [DataType](repeating: trillElType, count: Int(size)))
    case CXType_Elaborated:
      let element = clang_Type_getNamedType(type)
      return convertToTrillType(element)
    case CXType_IncompleteArray:
      let element = clang_getArrayElementType(type)
      guard let trillEltTy = convertToTrillType(element) else { return nil }
      return .pointer(type: trillEltTy)
    case CXType_Invalid:
      return nil
    case CXType_BlockPointer:
      // C/Obj-C Blocks are unexposed, but are always pointers.
      return .pointer(type: .int8)
    default:
      return nil
    }
  }

  func convertFunctionType(_ type: CXType) -> DataType? {
    let ret = clang_getResultType(type)
    let trillRet = convertToTrillType(ret) ?? .void
    let numArgs = clang_getNumArgTypes(type)
    let isVarArg = clang_isFunctionTypeVariadic(type) != 0

    guard numArgs != -1 else { return nil }

    var args = [DataType]()
    for i in 0..<UInt32(numArgs) {
      let type = clang_getArgType(type, UInt32(i))
      guard let trillArgTy = convertToTrillType(type) else { return nil }
      args.append(trillArgTy)
    }
    return .function(args: args, returnType: trillRet, hasVarArgs: isVarArg)
  }

  var files = [String: SourceFile]()

  private func makeLocation(_ clangLocation: CXSourceLocation) -> Source.SourceLocation {
    var cxfile: CXFile?
    var line: UInt32 = 0
    var column: UInt32 = 0
    var offset: UInt32 = 0
    clang_getSpellingLocation(clangLocation, &cxfile, &line, &column, &offset)

    let fileName = clang_getFileName(cxfile).asSwift()
    let sourceFile: SourceFile
    if files.keys.contains(fileName) {
      sourceFile = files[fileName]!
    } else {
      if fileName != "<none>" {
        let fileURL = URL(fileURLWithPath: fileName)
        sourceFile = try! SourceFile(path: .file(fileURL), sourceFileManager: context.sourceFileManager)
      } else {
        sourceFile = try! SourceFile(path: .none, sourceFileManager: context.sourceFileManager)
      }
      files[fileName] = sourceFile
    }
    return SourceLocation(line: Int(line), column: Int(column), file: sourceFile,
                          charOffset: Int(offset))
  }

  private func makeRange(_ clangRange: CXSourceRange) -> Source.SourceRange {
    let start = clang_getRangeStart(clangRange)
    let end = clang_getRangeEnd(clangRange)
    return SourceRange(start: makeLocation(start),
                       end: makeLocation(end))
  }
}
