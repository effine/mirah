package org.mirah.typer
import java.util.*
import mirah.lang.ast.*

class Typer < NodeVisitor
  def initialize
    @trueobj = java::lang::Boolean.valueOf(true)
    @futures = HashMap.new
  end

  def infer(node:Node, expression:boolean=true)
    return nil if node.nil?
    TypeFuture(@futures[node] ||= visit(node, expression ? @trueobj : nil))
  end

  def infer(node:Object, expression:boolean=true)
    infer(Node(node), expression)
  end

  def inferAll(nodes:NodeList)
    types = ArrayList.new
    nodes.each {|n| types.add(infer(n))} if nodes
    types
  end

  def inferAll(args:Arguments)
    types = ArrayList.new
    arguments.required.each {|a| types.add(infer(a))} if arguments.required
    arguments.optional.each {|a| types.add(infer(a))} if arguments.optional
    types.add(infer(arguments.rest)) if arguments.rest
    arguments.required2.each {|a| types.add(infer(a))} if arguments.required2
    types.add(infer(arguments.block)) if arguments.block
    types
  end

  def inferAll(typeNames:TypeNameList)
    types = ArrayList.new
    typeNames.each {|n| types.add(resolve(TypeName(n).typeref))}
    types
  end

  def visitDefault(node, expression)
    ErrorType.new(["Inference error", node.position])
  end

  def visitFunctionalCall(call, expression)
    selfType = getScope(call).selfType
    mergeUnquotes(call.parameters)
    parameters = inferAll(call.parameters)
    parameters.add(BlockType.new) if call.block
    methodType = getMethodType(selfType, call.name.identifier, parameters)
    typer = self
    methodType.onUpdate do |x, resolvedType|
      if resolvedType.kind_of?(InlineCode)
        node = InlineCode(resolvedType).node
        call.parent.replaceChild(call, node)
        typer.infer(node, expression != nil)
      end
    end
    if parameters.size == 0
      # This might actually be a local access instead of a method call,
      # so try both. If the local works, we'll go with that. If not, we'll
      # leave the method call.
      local = LocalAccess.new(call.position, call.name)
      localType = getLocalType(getScope(call), local.name.identifier)
      @futures[local] = localType
      MaybeInline.new(call, methodType, local, localType)
    elsif parameters.size == 1
      # This might actually be a cast instead of a method call, so try
      # both. If the cast works, we'll go with that. If not, we'll leave
      # the method call.
      cast = Cast.new(call.position, TypeName(call.typeref), Node(call.parameters.get(0).clone))
      castType = resolve(call.typeref)
      @futures[cast] = castType
      MaybeInline.new(call, methodType, cast, castType)
    else
      methodType
    end
  end

  def visitCall(call, expression)
    target = infer(call.target)
    mergeUnquotes(call.parameters)
    parameters = inferAll(call.parameters)
    parameters.add(BlockType.new) if call.block
    methodType = getMethodType(target, call.name.identifier, parameters)
    typer = self
    methodType.onUpdate do |x, resolvedType|
      if resolvedType.kind_of?(InlineCode)
        node = InlineCode(resolvedType).node
        call.parent.replaceChild(call, node)
        typer.infer(node, expression != nil)
      end
    end
    if  parameters.size == 1
      # This might actually be a cast instead of a method call, so try
      # both. If the cast works, we'll go with that. If not, we'll leave
      # the method call.
      cast = Cast.new(call.position, TypeName(call.typeref), Node(call.parameters.get(0).clone))
      castType = resolve(call.typeref)
      @futures[cast] = castType
      MaybeInline.new(call, methodType, cast, castType)
    else
      methodType
    end
  end

  def visitColon2(colon2, expression)
    resolve(colon2.typeref)
  end

  def visitSuper(node, expression)
    method = MethodDefinition(node.findAncestor(MethodDefinition.class))
    target = getScope(node).selfType.superclass
    parameters = inferAll(node.parameters)
    parameters.add(BlockType.new) if node.block
    getMethodType(target, method.name.identifier, parameters)
  end

  def visitZSuper(node, expression)
    method = MethodDefinition(node.findAncestor(MethodDefinition.class))
    target = getScope(node).selfType.superclass
    parameters = inferAll(method.arguments)
    getMethodType(target, method.name.identifier, parameters)
  end

  def visitClassDefinition(classdef, expression)
    classdef.annotations.each {|a| infer(a)}
    interfaces = inferAll(classdef.interfaces)
    superclass = resolve(classdef.superclass.typeref)
    type = defineType(classdef, classdef.name.identifier, superclass, interfaces)
    scope = addScope(classdef)
    scope.selfType = type
    infer(classdef.body, false) if classdef.body
    type
  end

  def visitFieldDeclaration(decl, expression)
    decl.annotations.each {|a| infer(a)}
    targetType = getScope(decl).selfType
    targetType = targetType.meta if decl.isStatic
    getField(targetType, decl.name.identifier).declare(resolve(type.typeref), decl.position)
  end


  def visitFieldAssign(field, expression)
    field.annotations.each {|a| infer(a)}
    targetType = getScope(field).selfType
    targetType = targetType.meta if field.isStatic
    value = infer(field.value, true)
    getField(targetType, field.name.identifier).assign(value, field.position)
  end

  def visitFieldAccess(field, expression)
    targetType = getScope(field).selfType
    targetType = targetType.meta if field.isStatic
    getField(targetType, field.name.identifier)
  end

  def visitConstant(constant, expression)
    resolve(constant.typeref)
  end

  def visitIf(stmt, expression)
    infer(stmt.condition, true)
    a = infer(stmt.body, expression != nil) if stmt.body
    b = infer(stmt.elseBody, expression != nil) if stmt.elseBody
    if expression && a && b
      type = AssignableTypeFuture.new(stmt.position)
      type.assign(a, stmt.body.position)
      type.assign(b, stmt.elseBody.position)
      type
    else
      a || b
    end
  end

  def visitLoop(node, expression)
    infer(node.condition, true)
    infer(node.body, false)
    infer(node.init, false)
    infer(node.pre, false)
    infer(node.post, false)
    getNullType()
  end

  def visitReturn(node, expression)
    type = if node.value
      infer(node.value)
    else
      getNoType()
    end
    method = MethodDefinition(node.findAncestor(MethodDefinition.class))
    parameters = inferAll(method.arguments)
    target = getScope(method).selfType
    getMethodDefType(target, method.name.identifier, parameters).assign(type, node.position)
  end

  def visitBreak(node, expression)
    getNullType()
  end

  def visitNext(node, expression)
    getNullType()
  end

  def visitRedo(node, expression)
    getNullType()
  end

  def visitRaise(node, expression)
    # Ok, this is complicated. There's three acceptable syntaxes
    #  - raise exception_object
    #  - raise ExceptionClass, *constructor_args
    #  - raise *args_for_default_exception_class_constructor
    # We need to figure out which one is being used, and replace the
    # args with a single exception node.

    # Start by saving the old args and creating a new, empty arg list
    exceptions = ArrayList.new
    old_args = node.args
    node.args = NodeList.new(node.args.position)

    # Create a node for syntax 1 if possible.
    if parameters.size == 1
      exceptions.add(infer(old_args.get(0)))
      exceptions.add(old_args.get(0).clone)
    end

    # Create a node for syntax 2 if possible.
    if parameters.size > 0
      target = Node(old_args.get(0).clone)
      params = ArrayList.new
      1.upto(old_args.size - 1) {|i| params.add(old_args.get(i).clone)}
      call = Call.new(target, SimpleString.new(node.position, 'new'), params, nil)
      exceptions.add(infer(call))
      exceptions.add(call)
    end

    # Create a node for syntax 3.
    target = getDefaultException().meta
    params = ArrayList.new
    old_args.each {|a| params.add(a.clone)}
    call = Call.new(target, SimpleString.new(node.position, 'new'), params, nil)
    exceptions.add(infer(call))
    exceptions.add(call)

    # Now we'll try all of these, ignoring any that cause an inference error.
    # Then we'll take the first that succeeds, in the order listed above.
    exceptionPicker = PickFirst.new(exceptions) do |type, pickedNode|
      if node.args.size == 0
        node.args.add(Node(pickedNode))
      else
        node.args.set(0, Node(pickedNode))
      end
    end

    # We need to ensure that the chosen node is an exception.
    # So create a dummy type declared as an exception, and assign
    # the picker to it.
    exceptionType = AssignableTypeFuture.new(node.position)
    exceptionType.declare(getBaseException(), node.position)
    assignment = exceptionType.assign(exceptionPicker, node.position)

    # Now we're ready to return our type. It should be UnreachableType.
    # But if none of the nodes is an exception, we need to return
    # an error.
    myType = BaseTypeFuture.new(node.position)
    unreachable = UnreachableType.new
    assignment.onUpdate do |x, resolved|
      if resolved.name == ':error'
        myType.resolved(resolved)
      else
        myType.resolved(unreachable)
      end
    end
    myType
  end

  def visitRescueClause(clause, expression)
    scope = addScope(clause)
    scope.parent = getScope(clause)
    if clause.name
      scope.shadow(name.identifier)
      exceptionType = getLocalType(scope, name.identifier)
      clause.types.each do |_t|
        t = TypeName(t)
        exceptionType.assign(resolve(t.typeref), t.position)
      end
    else
      inferAll(clause.types)
    end
    # What if body is nil?
    infer(clause.body, expression != nil)
  end

  def visitRescue(node, expression)
    bodyType = infer(node.body, expression && node.elseClause.nil?) if node.body
    elseType = infer(node.elseClause, expression != nil) if node.elseClause
    if expression
      myType = AssignableTypeFuture.new(node.position)
      if node.elseClause
        myType.assign(elseType, node.elseClause.position)
      else
        myType.assign(bodyType, node.body.position)
      end
    end
    node.clauses.each do |clause|
      clauseType = infer(clause, expression != nil)
      myType.assign(clauseType, Node(clause).position) if expression
    end
    myType || getNullType
  end

  def visitEnsure(node, expression)
    infer(node.ensureClause, false)
    infer(node.body, expression)
  end

  def visitArray(array, expression)
    mergeUnquotes(array.values)
    inferAll(array.values)
    getArrayType()
  end

  def visitFixnum(fixnum, expression)
    getFixnumType(fixnum.value)
  end

  def visitFloat(number, expression)
    getFloatType(number.value)
  end

  def visitHash(hash, expression)
    target = TypeRefImpl.new('mirah.impl.Builtin', false, true, hash.position)
    call = Call.new(target, SimpleString.new('new_hash'), nil, nil)
    hash.parent.replaceChild(hash, call)
    call.parameters.add(hash)
    infer(call, expression != nil)
  end

  def visitRegex(regex, expression)
    regex.strings.each {|r| infer(r)}
    getRegexType()
  end

  def visitSimpleString(string, expression)
    getStringType()
  end

  def visitStringConcat(string, expression)
    string.strings.each {|s| infer(s)}
    getStringType()
  end

  def visitStringEval(string, expression)
    infer(string.value)
    getStringType()
  end

  def visitBoolean(bool, expression)
    getBooleanType()
  end

  def visitNull(node, expression)
    getNullType()
  end

  # What about ImplicitNil? Should it be void? null?

  def visitCharLiteral(node, expression)
    getCharType(node.value)
  end

  def visitSelf(node, expression)
    getScope(node).selfType
  end

  def visitTypeRefImpl(typeref, expression)
    resolve(typeref)
  end

  def visitLocalDeclaration(decl, expression)
    type = resolve(decl.type.typeref)
    getLocalType(getScope(decl), decl.name.identifier).declare(type, decl.position)
  end

  def visitLocalAssign(local, expression)
    value = infer(local.value, true)
    getLocalType(getScope(local), local.name.identifier).assign(value, local.position)
  end

  def visitLocalAccess(local, expression)
    getLocalType(getScope(local), field.name.identifier)
  end

  def visitBody(body, expression)
    (body.size - 1).times do |i|
      infer(body.get(i), false)
    end
    if body.size > 0
      infer(body.get(body.size - 1), expression != null)
    else
      getNullType()
    end
  end

  def visitClassAppendSelf(node, expression)
    scope = addScope(node)
    scope.selfType = getScope(node).selfType.meta
    infer(node.body, false)
    getNullType()
  end

  def visitNoop(noop, expression)
    getVoidType()
  end

  def visitScript(script, expression)
    scope = getScope(script)
    scope.selfType = getMainType(script)
    infer(script.body, false)
  end

  def visitAnnotation(anno, expression)
    anno.values.entries_size.times do |i|
      infer(anno.values.entries(i).value)
    end
    resolve(anno.type.typeref)
  end

  def visitImport(node, expression)
    scope = getScope(node)
    fullName = node.fullName.identifier
    simpleName = node.simpleName.identifier
    scope.import(fullName, simpleName)
    unless '*'.equals(simpleName)
      resolve(TypeName(node.fullName))
    end
    getVoidType()
  end

  def visitPackage(node, expression)
    if node.body
      scope = addScope(node)
      scope.parent = getScope(node)
      infer(node.body, false)
    else
      scope = getScope(node)
    end
    scope.package = node.name.identifier
    getVoidType()
  end

  def visitEmptyArray(node, expression)
    infer(node.size)
    resolve(node.type).array
  end

  def visitUnquote(node, expression)
    node.nodes.each {|n| infer(n, expression != nil)}
  end

  def visitUnquoteAssign(node, expression)
    infer(node.node, expression != nil)
  end

  def visitArguments(args, expression)
    # Merge in any unquoted arguments first.
    it = args.required.listIterator
    mergeArgs(args, it, it, args.optional.listIterator(args.optional_size), args.required2.listIterator(args.required2_size))
    it = args.optional.listIterator
    mergeArgs(args, it, args.required.listIterator(args.required_size), it, args.required2.listIterator(args.required2_size))
    it = args.required.listIterator
    mergeArgs(args, it, args.required.listIterator(args.required_size), args.optional.listIterator(args.optional_size), it)
    # Then do normal type inference.
    inferAll(args)
    getVoidType()
  end

  def mergeArgs(args:Arguments, it:ListIterator, req:ListIterator, opt:ListIterator, req2:ListIterator):void
    it.each do |arg|
      name = Named(arg).name
      next unless name.kind_of?(Unquote)
      unquote = Unquote(name)
      new_args = unquote.arguments
      next unless new_args
      it.remove
      mergeIterators(new_args.required.listIterator, req)
      mergeIterators(new_args.optional.listIterator, opt)
      mergeIterators(new_args.required2.listIterator, req2)
      if new_args.rest
        raise IllegalArgumentException, "Only one rest argument allowed." if args.rest
        rest = new_args.rest
        new_args.rest = nil
        args.rest = rest
      end
      if new_args.block
        raise IllegalArgumentException, "Only one block argument allowed" if args.block
        block = new_args.block
        new_args.block = nil
        args.block = block
      end
    end
  end

  def mergeIterators(source:ListIterator, dest:ListIterator):void
    source.each do |a|
      source.remove
      dest.add(a)
    end
  end

  def mergeUnquotes(list:NodeList):void
    it = list.listIterator
    it.each do |item|
      if item.kind_of?(Unquote)
        it.remove
        Unquote(item).nodes.each do |node|
          it.add(node)
        end
      end
    end
  end

  def visitRequiredArgument(arg, expression)
    scope = getScope(arg)
    type = getLocalType(scope, arg.name.identifier)
    if arg.type
      type.declare(resolve(arg.type.typeref), arg.type.position)
    else
      type
    end
  end

  def visitOptionalArgument(arg, expression)
    scope = getScope(arg)
    type = getLocalType(scope, arg.name.identifier)
    type.declare(resolve(arg.type.typeref), arg.type.position) if arg.type
    type.assign(infer(arg.value), arg.value.position)
  end

  def visitRestArgument(arg, expression)
    scope = getScope(arg)
    type = getLocalType(scope, arg.name.identifier)
    if arg.type
      type.declare(resolve(arg.type.typeref).array, arg.type.position)
    else
      type
    end
  end

  def visitBlockArgument(arg, expression)
    scope = getScope(arg)
    type = getLocalType(scope, arg.name.identifier)
    if arg.type
      type.declare(resolve(arg.type.typeref), arg.type.position)
    else
      type
    end
  end

  def visitMethodDefinition(mdef, expression)
    # TODO optional arguments
    scope = addScope(mdef)
    selfType = getScope(mdef).selfType
    if mdef.kind_of?(StaticMethodDefinition)
      selfType = selfType.meta
    end
    scope.selfType = selfType
    scope.resetDefaultSelfNode
    inferAll(mdef.annotations)
    infer(arguments)
    parameters = inferAll(arguments)
    type = getMethodDefType(selfType, mdef.name.identifier, parameters)
    if mdef.type
      returnType = resolve(mdef.type.typeref)
      type.declare(returnType, mdef.type.position)
      if getVoidType().equals(returnType)
        expression = nil
      end
    end
    # TODO throws
    # mdef.exceptions.each {|e| type.throws(resolve(TypeName(e).typeref))}
    if mdef.body
      if expression
        type.assign(infer(mdef.body), mdef.body.position)
      else
        infer(mdef.body, false)
      end
    end
    type
  end

  def visitStaticMethodDefinition(mdef, expression)
    visitMethodDefinition(mdef, expression)
  end

  # TODO is a constructor special?

  # TODO
  # def visitBlock(block, expression)
  # end
  # 
  # def visitMacroDefinition(defn, expression)
  #   buildAndLoadExtension(defn)
  #   defn.getParent.removeChild(defn)
  #   getVoidType()
  # end
end