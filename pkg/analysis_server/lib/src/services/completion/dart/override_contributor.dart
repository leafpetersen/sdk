// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:analysis_server/src/protocol_server.dart'
    show CompletionSuggestion, CompletionSuggestionKind;
import 'package:analysis_server/src/protocol_server.dart' as protocol
    hide CompletionSuggestion, CompletionSuggestionKind;
import 'package:analysis_server/src/provisional/completion/completion_core.dart';
import 'package:analysis_server/src/provisional/completion/dart/completion_dart.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/src/dart/analysis/driver.dart';
import 'package:analyzer/src/dart/resolver/inheritance_manager.dart';
import 'package:analyzer_plugin/src/utilities/completion/completion_target.dart';
import 'package:analyzer_plugin/utilities/change_builder/change_builder_dart.dart';
import 'package:analyzer_plugin/utilities/range_factory.dart';

/**
 * A completion contributor used to suggest replacing partial identifiers inside
 * a class declaration with templates for inherited members.
 */
class OverrideContributor implements DartCompletionContributor {
  @override
  Future<List<CompletionSuggestion>> computeSuggestions(
      DartCompletionRequest request) async {
    SimpleIdentifier targetId = _getTargetId(request.target);
    if (targetId == null) {
      return EMPTY_LIST;
    }
    ClassDeclaration classDecl =
        targetId.getAncestor((p) => p is ClassDeclaration);
    if (classDecl == null) {
      return EMPTY_LIST;
    }

    // Generate a collection of inherited members
    ClassElement classElem = classDecl.element;
    InheritanceManager manager = new InheritanceManager(classElem.library);
    Map<String, ExecutableElement> map =
        manager.getMembersInheritedFromInterfaces(classElem);
    List<String> memberNames = _computeMemberNames(map, classElem);

    // Build suggestions
    List<CompletionSuggestion> suggestions = <CompletionSuggestion>[];
    for (String memberName in memberNames) {
      ExecutableElement element = map[memberName];
      // Gracefully degrade if the overridden element has not been resolved.
      if (element.returnType != null) {
        CompletionSuggestion suggestion =
            await _buildSuggestion(request, targetId, element);
        if (suggestion != null) {
          suggestions.add(suggestion);
        }
      }
    }
    return suggestions;
  }

  /**
   * Return a template for an override of the given [element]. If selected, the
   * template will replace [targetId].
   */
  Future<String> _buildReplacementText(AnalysisResult result,
      SimpleIdentifier targetId, ExecutableElement element) async {
    DartChangeBuilder builder =
        new DartChangeBuilder(result.driver.currentSession);
    await builder.addFileEdit(result.path, (DartFileEditBuilder builder) {
      builder.addReplacement(range.node(targetId), (DartEditBuilder builder) {
        builder.writeOverrideOfInheritedMember(element);
      });
    });
    return builder.sourceChange.edits[0].edits[0].replacement.trim();
  }

  /**
   * Build a suggestion to replace [targetId] in the given [unit]
   * with an override of the given [element].
   */
  Future<CompletionSuggestion> _buildSuggestion(DartCompletionRequest request,
      SimpleIdentifier targetId, ExecutableElement element) async {
    String completion =
        await _buildReplacementText(request.result, targetId, element);
    if (completion == null || completion.length == 0) {
      return null;
    }
    CompletionSuggestion suggestion = new CompletionSuggestion(
        CompletionSuggestionKind.IDENTIFIER,
        DART_RELEVANCE_HIGH,
        completion,
        targetId.offset,
        0,
        element.isDeprecated,
        false);
    suggestion.element = protocol.convertElement(element);
    return suggestion;
  }

  /**
   * Return a list containing the names of all of the inherited but not
   * implemented members of the class represented by the given [element].
   * The [map] is used to find all of the members that are inherited.
   */
  List<String> _computeMemberNames(
      Map<String, ExecutableElement> map, ClassElement element) {
    List<String> memberNames = <String>[];
    for (String memberName in map.keys) {
      if (!_hasMember(element, memberName)) {
        memberNames.add(memberName);
      }
    }
    return memberNames;
  }

  /**
   * If the target looks like a partial identifier inside a class declaration
   * then return that identifier, otherwise return `null`.
   */
  SimpleIdentifier _getTargetId(CompletionTarget target) {
    AstNode node = target.containingNode;
    if (node is ClassDeclaration) {
      Object entity = target.entity;
      if (entity is FieldDeclaration) {
        NodeList<VariableDeclaration> variables = entity.fields.variables;
        if (variables.length == 1) {
          SimpleIdentifier targetId = variables[0].name;
          if (targetId.name.isEmpty) {
            return targetId;
          }
        }
      }
    }
    return null;
  }

  /**
   * Return `true` if the given [classElement] directly declares a member with
   * the given [memberName].
   */
  bool _hasMember(ClassElement classElement, String memberName) {
    return classElement.getField(memberName) != null ||
        classElement.getGetter(memberName) != null ||
        classElement.getMethod(memberName) != null ||
        classElement.getSetter(memberName) != null;
  }
}
