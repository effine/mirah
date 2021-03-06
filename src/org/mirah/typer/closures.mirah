# Copyright (c) 2012 The Mirah project authors. All Rights Reserved.
# All contributing project authors may be found in the NOTICE file.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

package org.mirah.typer

import mirah.lang.ast.*
import java.util.Collections

# This class transforms a Block into an anonymous class once the Typer has figured out
# the interface to implement (or the abstract superclass).
#
# Note: This is ugly. It depends on the internals of the JVM scope and jvm_bytecode classes,
# and the BindingReference node is a hack. This should really all be cleaned up.
class ClosureBuilder
  def initialize(typer: Typer)
    @typer = typer
    @types = typer.type_system
    @scoper = typer.scoper
  end

  def prepare(block: Block, parent_type: ResolvedType)
    enclosing_node = block.findAncestor {|node| node.kind_of?(MethodDefinition) || node.kind_of?(Script)}
    enclosing_body = if enclosing_node.kind_of?(MethodDefinition)
      MethodDefinition(enclosing_node).body
    else
      Script(enclosing_node).body
    end

    klass = build_class(block.position, parent_type)
    insert_into_body enclosing_body, klass

    # TODO(ribrdb) binding
    parent_scope = @scoper.getScope(block)
    build_constructor(enclosing_body, klass, parent_scope)

    if contains_methods(block)
      copy_methods(klass, block, parent_scope)
    else
      build_method(klass, block, parent_type, parent_scope)
    end

    new_closure_call_node(block, klass)
  end

  def new_closure_call_node(block: Block, klass: Node): Call
    closure_type = infer(klass)
    target = makeTypeName(block.position, closure_type.resolve)
    Call.new(block.position, target, SimpleString.new("new"), [BindingReference.new], nil)
  end

  # Builds an anonymous class.
  def build_class(position: Position, parent_type: ResolvedType)
    interfaces = if (parent_type && parent_type.isInterface)
                   [makeTypeName(position, parent_type)]
                 else
                   Collections.emptyList
                 end
    superclass = if (parent_type.nil? || parent_type.isInterface)
                   nil
                 else
                   makeTypeName(position, parent_type)
                 end
    ClosureDefinition.new(position, nil, superclass, Collections.emptyList, interfaces, nil)
  end

  def makeTypeName(position: Position, type: ResolvedType)
    Constant.new(position, SimpleString.new(position, type.name))
  end

  # Copies MethodDefinition nodes from block to klass.
  def copy_methods(klass: ClassDefinition, block: Block, parent_scope: Scope): void
    block.body_size.times do |i|
      node = block.body(i)
      # TODO warn if there are non method definition nodes
      # they won't be used at all currently--so it'd be nice to note that.
      if node.kind_of?(MethodDefinition)
        cloned = MethodDefinition(node.clone)
        set_parent_scope cloned, parent_scope
        klass.body.add(cloned)
      end
    end
  end

  # Returns true if any MethodDefinitions were found.
  def contains_methods(block: Block): boolean
    block.body_size.times do |i|
      node = block.body(i)
      return true if node.kind_of?(MethodDefinition)
    end
    return false
  end

  # Builds MethodDefinitions in klass for the abstrace methods in iface.
  def build_method(klass: ClassDefinition, block: Block, iface: ResolvedType, parent_scope: Scope)
    methods = @types.getAbstractMethods(iface)
    if methods.size != 1
      raise UnsupportedOperationException, "Multiple abstract methods in #{iface}: #{methods}"
    end
    methods.each do |_m|
      mtype = MethodType(_m)
      name = SimpleString.new(block.position, mtype.name)
      args = if block.arguments
               Arguments(block.arguments.clone)
             else
               Arguments.new(block.position, Collections.emptyList, Collections.emptyList, nil, Collections.emptyList, nil)
             end
      while args.required.size < mtype.parameterTypes.size
        arg = RequiredArgument.new(block.position, SimpleString.new("arg#{args.required.size}"), nil)
        args.required.add(arg)
      end
      return_type = makeTypeName(block.position, mtype.returnType)
      method = MethodDefinition.new(block.position, name, args, return_type, nil, nil)
      method.body = NodeList(block.body.clone)

      set_parent_scope method, parent_scope

      klass.body.add(method)
    end
  end

  def build_constructor(enclosing_body: NodeList, klass: ClassDefinition, parent_scope: Scope): void
    parent_scope.binding_type ||= begin
                                    binding_klass = build_class(klass.position, nil)
                                    insert_into_body enclosing_body, binding_klass
                                    infer(binding_klass).resolve
                                  end
    binding_type_name = makeTypeName(klass.position, parent_scope.binding_type)
    args = Arguments.new(klass.position,
                         [RequiredArgument.new(SimpleString.new('binding'), binding_type_name)],
                         Collections.emptyList,
                         nil,
                         Collections.emptyList,
                         nil)
    body = FieldAssign.new(SimpleString.new('binding'), LocalAccess.new(SimpleString.new('binding')), nil)
    constructor = ConstructorDefinition.new(SimpleString.new('initialize'), args, SimpleString.new('void'), [body], nil)
    klass.body.add(constructor)
  end

  def insert_into_body enclosing_body: NodeList, klass: ClassDefinition
    enclosing_body.insert(0, klass)
  end

  def infer node: Node
    @typer.infer node
  end

  def set_parent_scope method: MethodDefinition, parent_scope: Scope
    @scoper.addScope(method).parent = parent_scope
  end
end
