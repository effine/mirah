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

import java.util.*
import java.util.concurrent.locks.ReentrantLock
import java.util.logging.Logger
import java.util.logging.Level
import mirah.lang.ast.*

# A TypeFuture that can be assigned to several times, and widens to a type
# that will hold all the assignments. It may also have a declared type, in
# which case all assignments must be compatible with the declared type.
class AssignableTypeFuture < BaseTypeFuture
  def initialize(position:Position)
    super(position)
    @assignments = LinkedHashMap.new
    @declarations = LinkedHashMap.new
    @lock = ReentrantLock.new
  end

  def self.initialize:void
    @@log = Logger.getLogger(AssignableTypeFuture.class.getName)
  end

  # Set the declared type. Only one declaration is allowed.
  def declare(type:TypeFuture, position:Position):TypeFuture
    @lock.lock
    base_type = self
    if @declarations.containsKey(type)
      TypeFuture(@declarations[type])
    elsif @declarations.isEmpty
      type.onUpdate do |t, value|
        base_type.resolved(value)
      end
      self.position = position
      @declarations[type] = self
      TypeFuture(self)
    else
      TypeFuture(@declarations[type] = ErrorType.new([['Type redeclared', position], ['First declared', self.position]]))
    end
  ensure
    @lock.unlock
  end

  # Adds an assigment. The returned future will resolve to 'value',
  # or an error if this assignment is incompatible.
  def assign(value:TypeFuture, position:Position):TypeFuture
    @lock.lock
    if @assignments.containsKey(value)
      TypeFuture(@assignments[value])
    else
      variable = self
      assignment = AssignmentFuture.new(self, value, position)
      @assignments[value] = assignment
      value.onUpdate do |x, resolved|
        variable.checkAssignments
        if resolved.isError
          assignment.resolved(resolved)
        elsif variable.isResolved
          if variable.resolve.assignableFrom(resolved)
            assignment.resolved(resolved)
          else
            assignment.resolved(variable.incompatibleWith(value.resolve, position))
          end
        end
      end
      TypeFuture(assignment)
    end
  ensure
    @lock.unlock
  end

  # Returns an error type for an incompatible assignment.
  # Subclasses may override this to customize the error message.
  def incompatibleWith(value:ResolvedType, position:Position)
    ErrorType.new([["Cannot assign #{value} to #{inferredType}", position]])
  end

  def hasDeclaration:boolean
    @lock.lock
    !@declarations.isEmpty
  ensure
    @lock.unlock
  end

  def assignedValues(includeParent:boolean, includeChildren:boolean):Collection
    @lock.lock
    Collection(@assignments.keySet)
  ensure
    @lock.unlock
  end

  def print(out:FuturePrinter)
    if hasDeclaration
      decl = TypeFuture(@declarations.keySet.iterator.next)
      out.print("declared: ")
      out.printFuture(decl)
    end
    assignedValues(true, true).each do |_value|
      value = TypeFuture(_value)
      out.printFuture(value)
      unless value.isResolved
        out.puts "(resolved: #{value.resolve})"
      end
    end
  end

  def checkAssignments:void
    if hasDeclaration
      return
    end
    if @checking
      return
    end
    begin
      @checking = true
      type = ResolvedType(nil)
      error = ResolvedType(nil)
      values = LinkedHashSet.new(assignedValues(true, true))
      errors = HashSet.new

      saved_type = if isResolved
        self.resolve
      else
        nil
      end

      # Loop through the assigned values and widen
      values.each do |_value|
        value = TypeFuture(_value)
        if value.isResolved
          resolved = value.resolve
          if resolved.isError
            @@log.finest("#{self}: found error #{resolved}")
            errors.add(value)
            error ||= resolved
          else
            @@log.finest("#{self}: adding type #{resolved}")
            if type
              type = type.widen(value.resolve)
            else
              type = resolved
            end
          end
        else
          errors.add(value)
        end
        nil
      end
      # Try committing the type
      @@log.finer("#{self}: checkAssignments: resolving as #{type || error}")
      resolved(type || error)
      @@log.finest("#{self}: checkAssignments: checking for conflicts #{saved_type} #{type}")
    
      # Now check if that broke anything. Revert to our previous value
      if saved_type && type
        values.each do |_value|
          value = TypeFuture(value)
          is_resolved = value.isResolved && !value.resolve.isError
          unless is_resolved || errors.contains(value)
            @@log.fine("#{self}: checkAssignments: conflict found, reverting to #{saved_type}")
            resolved(saved_type)
            return
          end
        end
      end
    ensure
      @checking = false
    end
  end

  def resolve
    unless isResolved
      @lock.lock
      begin
        unless @resolving
          @resolving = true
          if hasDeclaration
            @@log.finer("#{self}: Resolving declarations")
            @declarations.keySet.each {|t| TypeFuture(t).resolve}
            @@log.finer("#{self}: done")
          else
            @@log.finer("#{self}: Resolving assignments")
            assignedValues(true, true).each {|v| TypeFuture(v).resolve }
            @@log.finer("#{self}: done")
          end
          @resolving = false
        end
      ensure
        @lock.unlock
      end
    end
    super
  end
end
