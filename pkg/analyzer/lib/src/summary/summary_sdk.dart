// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library analyzer.src.summary.summary_sdk;

import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/src/context/cache.dart' show CacheEntry;
import 'package:analyzer/src/context/context.dart';
import 'package:analyzer/src/dart/element/element.dart';
import 'package:analyzer/src/dart/element/type.dart';
import 'package:analyzer/src/generated/constant.dart';
import 'package:analyzer/src/generated/engine.dart';
import 'package:analyzer/src/generated/resolver.dart';
import 'package:analyzer/src/generated/sdk.dart';
import 'package:analyzer/src/generated/source.dart'
    show DartUriResolver, Source, SourceFactory, SourceKind;
import 'package:analyzer/src/summary/idl.dart';
import 'package:analyzer/src/summary/package_bundle_reader.dart';
import 'package:analyzer/src/summary/resynthesize.dart';
import 'package:analyzer/src/task/dart.dart';
import 'package:analyzer/task/dart.dart';
import 'package:analyzer/task/model.dart'
    show AnalysisTarget, ResultDescriptor, TargetedResult;

class SdkSummaryResultProvider implements SummaryResultProvider {
  final InternalAnalysisContext context;
  final PackageBundle bundle;
  final SummaryTypeProvider typeProvider = new SummaryTypeProvider();

  @override
  SummaryResynthesizer resynthesizer;

  SdkSummaryResultProvider(this.context, this.bundle, bool strongMode) {
    resynthesizer = new SdkSummaryResynthesizer(
        context, typeProvider, context.sourceFactory, bundle, strongMode);
    _buildCoreLibrary();
    _buildAsyncLibrary();
    resynthesizer.finalizeCoreAsyncLibraries();
    context.typeProvider = typeProvider;
  }

  @override
  bool compute(CacheEntry entry, ResultDescriptor result) {
    if (result == TYPE_PROVIDER) {
      entry.setValue(result, typeProvider, TargetedResult.EMPTY_LIST);
      return true;
    }
    AnalysisTarget target = entry.target;
    // Only SDK sources after this point.
    if (target.source == null || !target.source.isInSystemLibrary) {
      return false;
    }
    // Constant expressions are always resolved in summaries.
    if (result == CONSTANT_EXPRESSION_RESOLVED &&
        target is ConstantEvaluationTarget) {
      entry.setValue(result, true, TargetedResult.EMPTY_LIST);
      return true;
    }
    if (target is Source) {
      if (result == LIBRARY_ELEMENT1 ||
          result == LIBRARY_ELEMENT2 ||
          result == LIBRARY_ELEMENT3 ||
          result == LIBRARY_ELEMENT4 ||
          result == LIBRARY_ELEMENT5 ||
          result == LIBRARY_ELEMENT6 ||
          result == LIBRARY_ELEMENT7 ||
          result == LIBRARY_ELEMENT8 ||
          result == LIBRARY_ELEMENT9 ||
          result == LIBRARY_ELEMENT) {
        // TODO(scheglov) try to find a way to avoid listing every result
        // e.g. "result.whenComplete == LIBRARY_ELEMENT"
        String uri = target.uri.toString();
        LibraryElement libraryElement = resynthesizer.getLibraryElement(uri);
        entry.setValue(result, libraryElement, TargetedResult.EMPTY_LIST);
        return true;
      } else if (result == READY_LIBRARY_ELEMENT2 ||
          result == READY_LIBRARY_ELEMENT6 ||
          result == READY_LIBRARY_ELEMENT7) {
        entry.setValue(result, true, TargetedResult.EMPTY_LIST);
        return true;
      } else if (result == SOURCE_KIND) {
        String uri = target.uri.toString();
        SourceKind kind = _getSourceKind(uri);
        if (kind != null) {
          entry.setValue(result, kind, TargetedResult.EMPTY_LIST);
          return true;
        }
        return false;
      } else {
//        throw new UnimplementedError('$result of $target');
      }
    }
    if (target is LibrarySpecificUnit) {
      if (target.library == null || !target.library.isInSystemLibrary) {
        return false;
      }
      if (result == CREATED_RESOLVED_UNIT1 ||
          result == CREATED_RESOLVED_UNIT2 ||
          result == CREATED_RESOLVED_UNIT3 ||
          result == CREATED_RESOLVED_UNIT4 ||
          result == CREATED_RESOLVED_UNIT5 ||
          result == CREATED_RESOLVED_UNIT6 ||
          result == CREATED_RESOLVED_UNIT7 ||
          result == CREATED_RESOLVED_UNIT8 ||
          result == CREATED_RESOLVED_UNIT9 ||
          result == CREATED_RESOLVED_UNIT10 ||
          result == CREATED_RESOLVED_UNIT11 ||
          result == CREATED_RESOLVED_UNIT12) {
        entry.setValue(result, true, TargetedResult.EMPTY_LIST);
        return true;
      }
      if (result == COMPILATION_UNIT_ELEMENT) {
        String libraryUri = target.library.uri.toString();
        String unitUri = target.unit.uri.toString();
        CompilationUnitElement unit = resynthesizer.getElement(
            new ElementLocationImpl.con3(<String>[libraryUri, unitUri]));
        if (unit != null) {
          entry.setValue(result, unit, TargetedResult.EMPTY_LIST);
          return true;
        }
      }
    } else if (target is VariableElement) {
      if (result == PROPAGATED_VARIABLE || result == INFERRED_STATIC_VARIABLE) {
        entry.setValue(result, target, TargetedResult.EMPTY_LIST);
        return true;
      }
    }
    return false;
  }

  void _buildAsyncLibrary() {
    LibraryElement library = resynthesizer.getLibraryElement('dart:async');
    typeProvider.initializeAsync(library);
  }

  void _buildCoreLibrary() {
    LibraryElement library = resynthesizer.getLibraryElement('dart:core');
    typeProvider.initializeCore(library);
  }

  /**
   * Return the [SourceKind] of the given [uri] or `null` if it is unknown.
   */
  SourceKind _getSourceKind(String uri) {
    if (bundle.linkedLibraryUris.contains(uri)) {
      return SourceKind.LIBRARY;
    }
    if (bundle.unlinkedUnitUris.contains(uri)) {
      return SourceKind.PART;
    }
    return null;
  }
}

/**
 * The implementation of [SummaryResynthesizer] for Dart SDK.
 */
class SdkSummaryResynthesizer extends SummaryResynthesizer {
  final PackageBundle bundle;
  final Map<String, UnlinkedUnit> unlinkedSummaries = <String, UnlinkedUnit>{};
  final Map<String, LinkedLibrary> linkedSummaries = <String, LinkedLibrary>{};

  SdkSummaryResynthesizer(AnalysisContext context, TypeProvider typeProvider,
      SourceFactory sourceFactory, this.bundle, bool strongMode)
      : super(null, context, typeProvider, sourceFactory, strongMode) {
    for (int i = 0; i < bundle.unlinkedUnitUris.length; i++) {
      unlinkedSummaries[bundle.unlinkedUnitUris[i]] = bundle.unlinkedUnits[i];
    }
    for (int i = 0; i < bundle.linkedLibraryUris.length; i++) {
      linkedSummaries[bundle.linkedLibraryUris[i]] = bundle.linkedLibraries[i];
    }
  }

  @override
  LinkedLibrary getLinkedSummary(String uri) {
    return linkedSummaries[uri];
  }

  @override
  UnlinkedUnit getUnlinkedSummary(String uri) {
    return unlinkedSummaries[uri];
  }

  @override
  bool hasLibrarySummary(String uri) {
    return uri.startsWith('dart:');
  }
}

/**
 * An implementation of [DartSdk] which provides analysis results for `dart:`
 * libraries from the given summary file.  This implementation is limited and
 * suitable only for command-line tools, but not for IDEs - it does not
 * implement [sdkLibraries], [sdkVersion], [uris] and [fromFileUri].
 */
class SummaryBasedDartSdk implements DartSdk {
  final bool strongMode;
  SummaryDataStore _dataStore;
  InSummaryPackageUriResolver _uriResolver;
  PackageBundle _bundle;

  /**
   * The [AnalysisContext] which is used for all of the sources in this sdk.
   */
  InternalAnalysisContext _analysisContext;

  SummaryBasedDartSdk(String summaryPath, this.strongMode) {
    _dataStore = new SummaryDataStore(<String>[summaryPath]);
    _uriResolver = new InSummaryPackageUriResolver(_dataStore);
    _bundle = _dataStore.bundles.single;
  }

  /**
   * Return the [PackageBundle] for this SDK, not `null`.
   */
  PackageBundle get bundle => _bundle;

  @override
  AnalysisContext get context {
    if (_analysisContext == null) {
      AnalysisOptionsImpl analysisOptions = new AnalysisOptionsImpl()
        ..strongMode = strongMode;
      _analysisContext = new SdkAnalysisContext(analysisOptions);
      SourceFactory factory = new SourceFactory([new DartUriResolver(this)]);
      _analysisContext.sourceFactory = factory;
      _analysisContext.resultProvider =
          new SdkSummaryResultProvider(_analysisContext, _bundle, strongMode);
    }
    return _analysisContext;
  }

  @override
  List<SdkLibrary> get sdkLibraries {
    throw new UnimplementedError();
  }

  @override
  String get sdkVersion {
    throw new UnimplementedError();
  }

  @override
  List<String> get uris {
    throw new UnimplementedError();
  }

  @override
  Source fromFileUri(Uri uri) {
    return null;
  }

  @override
  SdkLibrary getSdkLibrary(String uri) {
    // This is not quite correct, but currently it's used only in
    // to report errors on importing or exporting of internal libraries.
    return null;
  }

  @override
  Source mapDartUri(String uriStr) {
    Uri uri = Uri.parse(uriStr);
    return _uriResolver.resolveAbsolute(uri);
  }
}

/**
 * Provider for analysis results.
 */
abstract class SummaryResultProvider extends ResultProvider {
  /**
   * The [SummaryResynthesizer] of this context, maybe `null`.
   */
  SummaryResynthesizer get resynthesizer;
}

/**
 * Implementation of [TypeProvider] which can be initialized separately with
 * `dart:core` and `dart:async` libraries.
 */
class SummaryTypeProvider implements TypeProvider {
  LibraryElement _coreLibrary;
  LibraryElement _asyncLibrary;

  InterfaceType _boolType;
  InterfaceType _deprecatedType;
  InterfaceType _doubleType;
  InterfaceType _functionType;
  InterfaceType _futureDynamicType;
  InterfaceType _futureNullType;
  InterfaceType _futureType;
  InterfaceType _intType;
  InterfaceType _iterableDynamicType;
  InterfaceType _iterableType;
  InterfaceType _listType;
  InterfaceType _mapType;
  DartObjectImpl _nullObject;
  InterfaceType _nullType;
  InterfaceType _numType;
  InterfaceType _objectType;
  InterfaceType _stackTraceType;
  InterfaceType _streamDynamicType;
  InterfaceType _streamType;
  InterfaceType _stringType;
  InterfaceType _symbolType;
  InterfaceType _typeType;

  @override
  InterfaceType get boolType {
    assert(_coreLibrary != null);
    _boolType ??= _getType(_coreLibrary, "bool");
    return _boolType;
  }

  @override
  DartType get bottomType => BottomTypeImpl.instance;

  @override
  InterfaceType get deprecatedType {
    assert(_coreLibrary != null);
    _deprecatedType ??= _getType(_coreLibrary, "Deprecated");
    return _deprecatedType;
  }

  @override
  InterfaceType get doubleType {
    assert(_coreLibrary != null);
    _doubleType ??= _getType(_coreLibrary, "double");
    return _doubleType;
  }

  @override
  DartType get dynamicType => DynamicTypeImpl.instance;

  @override
  InterfaceType get functionType {
    assert(_coreLibrary != null);
    _functionType ??= _getType(_coreLibrary, "Function");
    return _functionType;
  }

  @override
  InterfaceType get futureDynamicType {
    assert(_asyncLibrary != null);
    _futureDynamicType ??= futureType.instantiate(<DartType>[dynamicType]);
    return _futureDynamicType;
  }

  @override
  InterfaceType get futureNullType {
    assert(_asyncLibrary != null);
    _futureNullType ??= futureType.instantiate(<DartType>[_nullType]);
    return _futureNullType;
  }

  @override
  InterfaceType get futureType {
    assert(_asyncLibrary != null);
    _futureType ??= _getType(_asyncLibrary, "Future");
    return _futureType;
  }

  @override
  InterfaceType get intType {
    assert(_coreLibrary != null);
    _intType ??= _getType(_coreLibrary, "int");
    return _intType;
  }

  @override
  InterfaceType get iterableDynamicType {
    assert(_coreLibrary != null);
    _iterableDynamicType ??= iterableType.instantiate(<DartType>[dynamicType]);
    return _iterableDynamicType;
  }

  @override
  InterfaceType get iterableType {
    assert(_coreLibrary != null);
    _iterableType ??= _getType(_coreLibrary, "Iterable");
    return _iterableType;
  }

  @override
  InterfaceType get listType {
    assert(_coreLibrary != null);
    _listType ??= _getType(_coreLibrary, "List");
    return _listType;
  }

  @override
  InterfaceType get mapType {
    assert(_coreLibrary != null);
    _mapType ??= _getType(_coreLibrary, "Map");
    return _mapType;
  }

  @override
  List<InterfaceType> get nonSubtypableTypes => <InterfaceType>[
        nullType,
        numType,
        intType,
        doubleType,
        boolType,
        stringType
      ];

  @override
  DartObjectImpl get nullObject {
    if (_nullObject == null) {
      _nullObject = new DartObjectImpl(nullType, NullState.NULL_STATE);
    }
    return _nullObject;
  }

  @override
  InterfaceType get nullType {
    assert(_coreLibrary != null);
    _nullType ??= _getType(_coreLibrary, "Null");
    return _nullType;
  }

  @override
  InterfaceType get numType {
    assert(_coreLibrary != null);
    _numType ??= _getType(_coreLibrary, "num");
    return _numType;
  }

  @override
  InterfaceType get objectType {
    assert(_coreLibrary != null);
    _objectType ??= _getType(_coreLibrary, "Object");
    return _objectType;
  }

  @override
  InterfaceType get stackTraceType {
    assert(_coreLibrary != null);
    _stackTraceType ??= _getType(_coreLibrary, "StackTrace");
    return _stackTraceType;
  }

  @override
  InterfaceType get streamDynamicType {
    assert(_asyncLibrary != null);
    _streamDynamicType ??= streamType.instantiate(<DartType>[dynamicType]);
    return _streamDynamicType;
  }

  @override
  InterfaceType get streamType {
    assert(_asyncLibrary != null);
    _streamType ??= _getType(_asyncLibrary, "Stream");
    return _streamType;
  }

  @override
  InterfaceType get stringType {
    assert(_coreLibrary != null);
    _stringType ??= _getType(_coreLibrary, "String");
    return _stringType;
  }

  @override
  InterfaceType get symbolType {
    assert(_coreLibrary != null);
    _symbolType ??= _getType(_coreLibrary, "Symbol");
    return _symbolType;
  }

  @override
  InterfaceType get typeType {
    assert(_coreLibrary != null);
    _typeType ??= _getType(_coreLibrary, "Type");
    return _typeType;
  }

  @override
  DartType get undefinedType => UndefinedTypeImpl.instance;

  /**
   * Initialize the `dart:async` types provided by this type provider.
   */
  void initializeAsync(LibraryElement library) {
    assert(_coreLibrary != null);
    assert(_asyncLibrary == null);
    _asyncLibrary = library;
  }

  /**
   * Initialize the `dart:core` types provided by this type provider.
   */
  void initializeCore(LibraryElement library) {
    assert(_coreLibrary == null);
    assert(_asyncLibrary == null);
    _coreLibrary = library;
  }

  /**
   * Return the type with the given [name] from the given [library], or
   * throw a [StateError] if there is no class with the given name.
   */
  InterfaceType _getType(LibraryElement library, String name) {
    Element element = library.getType(name);
    if (element == null) {
      throw new StateError("No definition of type $name");
    }
    return (element as ClassElement).type;
  }
}
