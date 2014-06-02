# Unit tests

assert = require('chai').assert
rewire = require 'rewire'
sinon = require 'sinon'

Job = rewire '../src/job_class.coffee'

# Mock DDP class
class DDP

   call: (name, params, cb = null) ->
      console.log "DDP prototype call invoked with '#{name}'' method"
      unless cb? and typeof cb is 'function'
         switch name
            when 'root_true'
               return true
            when 'root_false'
               return false
            when 'root_param'
               return params[0]
            when 'root_error'
               throw new Error "Method failed"
         throw new Error "Bad method in call"
      else
         switch name
            when 'root_true'
               process.nextTick () -> cb null, true
            when 'root_false'
               process.nextTick () -> cb null, false
            when 'root_param'
               process.nextTick () -> cb null, params[0]
            when 'root_error'
               process.nextTick () -> cb new Error "Method failed"
         return

   loginWithToken: (token, cb) ->
      process.nextTick () -> cb(null, "fake_token")

describe 'Job', () ->

   it 'has class constants', () ->
      assert.isNumber Job.forever
      assert.isObject Job.jobPriorities
      assert.lengthOf Object.keys(Job.jobPriorities), 5
      assert.isArray Job.jobStatuses
      assert.lengthOf Job.jobStatuses, 7
      assert.isArray Job.jobLogLevels
      assert.lengthOf Job.jobLogLevels, 4
      assert.isArray Job.jobStatusCancellable
      assert.lengthOf Job.jobStatusCancellable, 4
      assert.isArray Job.jobStatusPausable
      assert.lengthOf Job.jobStatusPausable, 2
      assert.isArray Job.jobStatusRemovable
      assert.lengthOf Job.jobStatusRemovable, 3
      assert.isArray Job.jobStatusRestartable
      assert.lengthOf Job.jobStatusRestartable, 2

   it 'has a ddp_apply class variable that defaults as undefined outside of Meteor', () ->
      assert.isUndefined Job.ddp_apply

   it 'has a processJobs method that is the JobQueue constructor', () ->
      assert.equal Job.processJobs, Job.__get__ "JobQueue"

   describe 'setDDP', () ->

      ddp = new DDP()

      it 'throws if given a non-ddp object', () ->
         assert.throws (() -> Job.setDDP({})), /Bad ddp object/

      it 'properly sets the ddp_apply class variable', (done) ->
         sinon.stub(ddp, "call").yieldsAsync()
         Job.setDDP ddp
         Job.ddp_apply 'test', [], () ->
            assert ddp.call.calledOnce
            ddp.call.restore()
            done()

   describe 'private function', () ->

      # Note! These are internal helper functions, NOT part of the external API!
      describe 'methodCall', () ->

         ddp = new DDP()

         before () ->
            sinon.spy(ddp, "call")
            Job.setDDP ddp

         methodCall = Job.__get__ 'methodCall'

         it 'should be a function', () ->
            assert.isFunction methodCall

         it 'should invoke the correct ddp method', (done) ->
            methodCall "root", "true", [], (err, res) ->
               assert ddp.call.calledOnce
               assert ddp.call.calledWith("root_true")
               assert.isTrue res
               done()

         it 'should pass the correct method parameters', (done) ->
            methodCall "root", "param", ['a', 1, [1,2,3], { foo: 'bar'}], (err, res) ->
               assert ddp.call.calledOnce
               assert ddp.call.calledWith("root_param", ['a', 1, [1,2,3], { foo: 'bar'}])
               assert.equal res, 'a'
               done()

         it 'should invoke the after callback when provided', (done) ->
            after = sinon.stub().returns(true)
            methodCall("root", "false", []
               (err, res) ->
                  assert ddp.call.calledOnce
                  assert ddp.call.calledWith("root_false", [])
                  assert after.calledOnce
                  assert.isTrue res
                  done()
               after
            )

         it "shouldn't invoke the after callback when error", (done) ->
            after = sinon.stub().returns(true)
            methodCall("root", "error", []
               (err, res) ->
                  assert ddp.call.calledOnce
                  assert ddp.call.calledWith("root_error", [])
                  assert.equal after.callCount, 0, "After shouldn't be called"
                  assert.isUndefined res, "Result isn't undefined"
                  assert.throws (() -> throw err), /Method failed/
                  done()
               after
            )

         it 'should invoke the correct ddp method without callback', () ->
            res = methodCall "root", "true", []
            assert ddp.call.calledOnce
            assert ddp.call.calledWith("root_true")
            assert.isTrue res

         it 'should pass the correct method parameters without callback', () ->
            res = methodCall "root", "param", ['a', 1, [1,2,3], { foo: 'bar'}]
            assert ddp.call.calledOnce
            assert ddp.call.calledWith("root_param", ['a', 1, [1,2,3], { foo: 'bar'}])
            assert.equal res, 'a'

         it 'should invoke the after callback when provided without callback', () ->
            after = sinon.stub().returns(true)
            res = methodCall "root", "false", [], undefined, after
            assert ddp.call.calledOnce
            assert ddp.call.calledWith("root_false", [])
            assert after.calledOnce
            assert.isTrue res

         it "should throw on error when invoked without callback", () ->
            after = sinon.stub().returns(true)
            res = undefined
            assert.throws (() -> res = methodCall("root", "error", [], undefined, after)), /Method failed/
            assert ddp.call.calledOnce
            assert ddp.call.calledWith("root_error", [])
            assert.equal after.callCount, 0, "After shouldn't be called"
            assert.isUndefined res, "Result isn't undefined"

         afterEach () ->
            ddp.call.reset()

      describe 'optionsHelp', () ->

         optionsHelp = Job.__get__ 'optionsHelp'
         foo = { bar: "bat" }
         gizmo = () ->

         it 'should return options and a callback when both are provided', () ->
            res = optionsHelp [foo], gizmo
            assert.deepEqual res, [foo, gizmo]

         it 'should handle a missing callback and return only options', () ->
            res = optionsHelp [foo]
            assert.deepEqual res, [foo, undefined]

         it 'should handle missing options and return empty options and the callback', () ->
            res = optionsHelp [], gizmo
            assert.deepEqual res, [{}, gizmo]

         it 'should handle when both options and callback are missing', () ->
            res = optionsHelp([], undefined)
            assert.deepEqual res, [{}, undefined]

         it 'should throw an error when an invalid callback is provided', () ->
            assert.throws (()-> optionsHelp([foo], 5)), /options not an object or bad callback/

         it 'should throw an error when a non-array is passed for options', () ->
            assert.throws (()-> optionsHelp(foo, gizmo)), /must be an Array with zero or one elements/

         it 'should throw an error when a bad options array is passed', () ->
            assert.throws (()-> optionsHelp([foo, 5], gizmo)), /must be an Array with zero or one elements/

      describe 'splitLongArray', () ->

         splitLongArray = Job.__get__ 'splitLongArray'

         longArray = [ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 ]

         it 'should properly split an array', () ->
            res = splitLongArray longArray, 4
            assert.deepEqual res, [ [0, 1, 2, 3], [4, 5, 6, 7], [8, 9, 10, 11] ]

         it 'should handle remainders correctly', () ->
            res = splitLongArray longArray, 5
            assert.deepEqual res, [ [0, 1, 2, 3, 4], [5, 6, 7, 8, 9], [10, 11] ]

         it 'should handle an empty array', () ->
            res = splitLongArray [], 5
            assert.deepEqual res, []

         it 'should handle a single element array', () ->
            res = splitLongArray [0], 5
            assert.deepEqual res, [ [0] ]

         it 'should throw if not given an array', () ->
            assert.throws (() -> splitLongArray { foo: "bar"}, 5), /splitLongArray: bad params/

         it 'should throw if given an out of range max value', () ->
            assert.throws (() -> splitLongArray longArray, 0), /splitLongArray: bad params/

         it 'should throw if given an invalid max value', () ->
            assert.throws (() -> splitLongArray longArray, "cow"), /splitLongArray: bad params/

      describe 'concatReduce', () ->
         concatReduce = Job.__get__ 'concatReduce'

         it 'should concat a to b', () ->
            assert.deepEqual concatReduce([1],2), [1,2]

         it 'should work with non array for the first param', () ->
            assert.deepEqual concatReduce(1,2), [1,2]

      describe 'reduceCallbacks', () ->
         reduceCallbacks = Job.__get__ 'reduceCallbacks'

         it 'should return undefined if given a falsy callback', () ->
            assert.isUndefined reduceCallbacks(undefined, 5)

         it 'should properly absorb the specified number of callbacks', () ->
            spy = sinon.spy()
            cb = reduceCallbacks spy, 3
            cb null, true
            cb null, false
            cb null, true
            assert spy.calledOnce
            assert spy.calledWith null, true

         it 'should properly reduce the callback results', () ->
            spy = sinon.spy()
            cb = reduceCallbacks spy, 3
            cb null, false
            cb null, false
            cb null, false
            assert spy.calledOnce
            assert spy.calledWith null, false

         it 'should properly reduce with a custom reduce function', () ->
            concatReduce = Job.__get__ 'concatReduce'
            spy = sinon.spy()
            cb = reduceCallbacks spy, 3, concatReduce, []
            cb null, false
            cb null, true
            cb null, false
            assert spy.calledOnce, 'callback called too many times'
            assert spy.calledWith(null, [false, true, false]), 'Returned wrong result'

         it 'should throw if called too many times', () ->
            spy = sinon.spy()
            cb = reduceCallbacks spy, 2
            cb null, true
            cb null, true
            assert.throws cb, /reduceCallbacks callback invoked more than requested/

         it 'should throw if given a non-function callback', () ->
            assert.throws (() -> reduceCallbacks 5), /Bad params given to reduceCallbacks/

         it 'should throw if given an invalid number of callbacks to absorb', () ->
            assert.throws (() -> reduceCallbacks (() -> ), 'cow'), /Bad params given to reduceCallbacks/

         it 'should throw if given an out of range number of callbacks to absorb', () ->
            assert.throws (() -> reduceCallbacks (() -> ), 0), /Bad params given to reduceCallbacks/

         it 'should throw if given a non-function reduce', () ->
            assert.throws (() -> reduceCallbacks (() -> ), 5, 5), /Bad params given to reduceCallbacks/

      describe '_setImmediate', () ->

         _setImmediate = Job.__get__ '_setImmediate'

         it 'should invoke the provided callback with args', (done) ->
            cb = (a, b) ->
               assert.equal a, "foo"
               assert.equal b, "bar"
               done()
            _setImmediate cb, "foo", "bar"

      describe '_setInterval', () ->

         _setInterval = Job.__get__ '_setInterval'
         _clearInterval = Job.__get__ '_clearInterval'

         it 'should invoke the provided callback repeatedly with args', (done) ->
            cancel = null
            count = 0
            cb = (a, b) ->
               assert.equal a, "foo"
               assert.equal b, "bar"
               count++
               if count is 2
                  _clearInterval cancel
                  done()
               else if count > 2
                  throw "Interval called too many times"

            cancel = _setInterval cb, 10, "foo", "bar"


