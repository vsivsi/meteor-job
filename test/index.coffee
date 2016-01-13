############################################################################
#     Copyright (C) 2014-2016 by Vaughn Iverson
#     meteor-job-class is free software released under the MIT/X11 license.
#     See included LICENSE file for details.
############################################################################

# Unit tests

assert = require('chai').assert
rewire = require 'rewire'
sinon = require 'sinon'
Fiber = require 'fibers'

Job = rewire '../src/job_class.coffee'

# Mock DDP class
class DDP

   call: (name, params, cb = null) ->
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
            else
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
            else
               process.nextTick () -> cb new Error "Bad method in call"
      return

   connect: () ->
      process.nextTick () -> cb(null)

   close: () ->
      process.nextTick () -> cb(null)

   subscribe: () ->
      process.nextTick () -> cb(null)

   observe: () ->
      process.nextTick () -> cb(null)

makeDdpStub = (action) ->
   return (name, params, cb) ->
      [err, res] = action name, params
      # console.dir res
      if cb?
         return process.nextTick () -> cb err, res
      else if err
         throw err
      return res

###########################################

describe 'Job', () ->

   it 'has class constants', () ->
      assert.isNumber Job.forever
      assert.isObject Job.jobPriorities
      assert.lengthOf Object.keys(Job.jobPriorities), 5
      assert.isArray Job.jobRetryBackoffMethods
      assert.lengthOf Job.jobRetryBackoffMethods, 2
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
      assert.isArray Job.ddpPermissionLevels
      assert.lengthOf Job.ddpPermissionLevels , 4
      assert.isArray Job.ddpMethods
      assert.lengthOf Job.ddpMethods, 18
      assert.isObject Job.ddpMethodPermissions
      assert.lengthOf Object.keys(Job.ddpMethodPermissions), Job.ddpMethods.length

   it 'has a _ddp_apply class variable that defaults as undefined outside of Meteor', () ->
      assert.isUndefined Job._ddp_apply

   it 'has a processJobs method that is the JobQueue constructor', () ->
      assert.equal Job.processJobs, Job.__get__ "JobQueue"

   describe 'setDDP', () ->

      ddp = new DDP()

      describe 'default setup', () ->

         it 'throws if given a non-ddp object', () ->
            assert.throws (() -> Job.setDDP({})), /Bad ddp object/

         it 'properly sets the default _ddp_apply class variable', (done) ->
            sinon.stub(ddp, "call").yieldsAsync()
            Job.setDDP ddp
            Job._ddp_apply 'test', [], () ->
               assert ddp.call.calledOnce
               ddp.call.restore()
               done()

         it 'fails if subsequently called with a collection name', (done) ->
            assert.throws (() -> Job.setDDP ddp, 'test1'), /Job.setDDP must specify/
            done()

         after () ->
            Job._ddp_apply = undefined

      describe 'setup with collection name', () ->

         it 'properly sets the _ddp_apply class variable', (done) ->
            sinon.stub(ddp, "call").yieldsAsync()
            Job.setDDP ddp, 'test1'
            Job._ddp_apply.test1 'test', [], () ->
               assert ddp.call.calledOnce
               ddp.call.restore()
               done()

         it 'properly sets the _ddp_apply class variable when called with array', (done) ->
            sinon.stub(ddp, "call").yieldsAsync()
            Job.setDDP ddp, ['test2','test3']
            Job._ddp_apply.test2 'test', [], () ->
               Job._ddp_apply.test3 'test', [], () ->
                  assert.equal ddp.call.callCount, 2
                  ddp.call.restore()
                  done()

         it 'fails if subsequently called without a collection name', (done) ->
            assert.throws (() -> Job.setDDP ddp), /Job.setDDP must specify/
            done()

         after () ->
            Job._ddp_apply = undefined

   describe 'Fiber support', () ->

      ddp = new DDP()

      it 'accepts a valid collection name and Fiber object and properly yields and runs', (done) ->
         sinon.stub(ddp, "call").yieldsAsync()
         Job.setDDP ddp, 'test1', Fiber
         fib = Fiber () ->
            Job._ddp_apply.test1 'test', []
         fib.run()
         assert ddp.call.calledOnce
         ddp.call.restore()
         done()

      it 'accepts a default collection name and valid Fiber object and properly yields and runs', (done) ->
         sinon.stub(ddp, "call").yieldsAsync()
         Job.setDDP ddp, Fiber
         fib = Fiber () ->
            Job._ddp_apply 'test', []
         fib.run()
         assert ddp.call.calledOnce
         ddp.call.restore()
         done()

      it 'properly returns values from method calls', (done) ->
         Job.setDDP ddp, Fiber
         fib = Fiber () ->
            assert.isTrue Job._ddp_apply('root_true', [])
            assert.isFalse Job._ddp_apply('root_false', [])
            assert.deepEqual Job._ddp_apply('root_param', [['a', 1, null]]), ['a', 1, null]
            done()
         fib.run()

      it 'properly propagates thrown errors within a Fiber', (done) ->
         Job.setDDP ddp, Fiber
         fib = Fiber () ->
            assert.throws (() -> Job._ddp_apply 'root_error', []), /Method failed/
            assert.throws (() -> Job._ddp_apply 'bad_method', []), /Bad method in call/
            done()
         fib.run()

      afterEach () ->
         Job._ddp_apply = undefined

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

         after () ->
            Job._ddp_apply = undefined

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

   describe 'Job constructor', () ->

      checkJob = (job) ->
         assert.instanceOf job, Job
         assert.equal job.root, 'root'
         assert.equal job.type, 'work'
         assert.deepEqual job.data, { foo: "bar" }
         assert.isObject job._doc
         doc = job._doc
         assert.notProperty doc, '_id'
         assert.isNull doc.runId
         assert.equal job.type, doc.type
         assert.deepEqual job.data, doc.data
         assert.isString doc.status
         assert.instanceOf doc.updated, Date
         assert.isArray doc.depends
         assert.isArray doc.resolved
         assert.isNumber doc.priority
         assert.isNumber doc.retries
         assert.isNumber doc.retryWait
         assert.isNumber doc.retried
         assert.isString doc.retryBackoff
         assert.instanceOf doc.retryUntil, Date
         assert.isNumber doc.repeats
         assert.isNumber doc.repeatWait
         assert.isNumber doc.repeated
         assert.instanceOf doc.repeatUntil, Date
         assert.instanceOf doc.after, Date
         assert.isArray doc.log
         assert.isObject doc.progress
         assert.instanceOf doc.created, Date

      it 'should return a new valid Job object', () ->
         job = new Job('root', 'work', { foo: "bar" })
         checkJob job

      it 'should work without "new"', () ->
         job = Job('root', 'work', { foo: "bar" })
         checkJob job

      it 'should throw when given bad parameters', () ->
         assert.throw Job, /new Job: bad parameter/

      it 'should support using a valid job document', () ->
         job = new Job('root', 'work', { foo: "bar" })
         checkJob job
         job2 = new Job('root', job.doc)
         checkJob job2

      it 'should support using a valid oobject for root', () ->
         job = new Job({ root: 'root'}, 'work', { foo: "bar" })
         checkJob job
         job2 = new Job({ root: 'root'}, job.doc)
         checkJob job2

   describe 'job mutator method', () ->

      job = null
      doc = null

      beforeEach () ->
         job = Job('root', 'work', {})
         doc = job._doc

      describe '.depends()', () ->

         it 'should properly update the depends property', () ->
            jobA = Job('root', 'work', {})
            jobA._doc._id = 'foo'
            jobB = Job('root', 'work', {})
            jobB._doc._id = 'bar'
            j = job.depends [ jobA, jobB ]
            assert.equal j, job
            assert.deepEqual doc.depends, [ 'foo', 'bar' ]

         it 'should accept a singlet Job', () ->
            jobA = Job('root', 'work', {})
            jobA._doc._id = 'foo'
            j = job.depends jobA
            assert.equal j, job
            assert.deepEqual doc.depends, [ 'foo' ]

         it 'should accept an empty deps array and return the job unchanged', () ->
            jobA = Job('root', 'work', {})
            jobA._doc._id = 'foo'
            j = job.depends jobA
            assert.equal j, job
            assert.deepEqual doc.depends, [ 'foo' ]
            j = job.depends []
            assert.equal j, job
            assert.deepEqual doc.depends, [ 'foo' ]

         it 'should clear dependencies when passed a falsy value', () ->
            jobA = Job('root', 'work', {})
            jobA._doc._id = 'foo'
            j = job.depends jobA
            assert.equal j, job
            assert.deepEqual doc.depends, [ 'foo' ]
            job.depends null
            assert.lengthOf doc.depends, 0

         it 'should throw when given a bad parameter', () ->
            assert.throw (() -> job.depends "badness"), /Bad input parameter/

         it 'should throw when given an array containing non Jobs', () ->
            assert.throw (() -> job.depends ["Badness"]), /Each provided object/

         it 'should throw when given an array containing unsaved Jobs without an _id', () ->
            jobA = Job('root', 'work', {})
            assert.throw (() -> job.depends [ jobA ]), /Each provided object/

      describe '.priority()', () ->

         it 'should accept a numeric priority', () ->
            j = job.priority 3
            assert.equal j, job
            assert.equal doc.priority, 3

         it 'should accept a valid string priority', () ->
            j = job.priority 'normal'
            assert.equal j, job
            assert.equal doc.priority, Job.jobPriorities['normal']

         it 'should throw when given an invalid priority level', () ->
            assert.throw (() -> job.priority 'super'), /Invalid string priority level provided/

         it 'should throw when given an invalid parameter', () ->
            assert.throw (() -> job.priority []), /priority must be an integer or valid priority level/

         it 'should throw when given a non-integer', () ->
            assert.throw (() -> job.priority 3.14), /priority must be an integer or valid priority level/

      describe '.retry()', () ->

         it 'should accept a non-negative integer parameter', () ->
            j = job.retry 3
            assert.equal j, job
            assert.equal doc.retries, 3 + 1 # This is correct, it adds one.
            assert.equal doc.retryWait, 5*60*1000
            assert.equal doc.retryBackoff, 'constant'

         it 'should accept an option object', () ->
            j = job.retry { retries: 3, until: new Date(new Date().valueOf() + 60000), wait: 5000, backoff: 'exponential' }
            assert.equal j, job
            assert.equal doc.retries, 3 + 1
            assert.ok doc.retryUntil > new Date()
            assert.equal doc.retryWait, 5000
            assert.equal doc.retryBackoff, 'exponential'

         it 'should throw when given a bad parameter', () ->
            assert.throw (() -> job.retry 'badness'), /bad parameter: accepts either an integer/

         it 'should throw when given a negative integer', () ->
            assert.throw (() -> job.retry -1), /bad parameter: accepts either an integer/

         it 'should throw when given a numeric non-integer', () ->
            assert.throw (() -> job.retry 3.14), /bad parameter: accepts either an integer/

         it 'should throw when given bad options', () ->
            assert.throw (() -> job.retry { retries: 'badness' }), /bad option: retries must be an integer/
            assert.throw (() -> job.retry { retries: -1 }), /bad option: retries must be an integer/
            assert.throw (() -> job.retry { retries: 3.14 }), /bad option: retries must be an integer/
            assert.throw (() -> job.retry { wait: 'badness' }), /bad option: wait must be an integer/
            assert.throw (() -> job.retry { wait: -1 }), /bad option: wait must be an integer/
            assert.throw (() -> job.retry { wait: 3.14 }), /bad option: wait must be an integer/
            assert.throw (() -> job.retry { backoff: 'bogus' }), /bad option: invalid retry backoff method/
            assert.throw (() -> job.retry { until: 'bogus' }), /bad option: until must be a Date object/

      describe '.repeat()', () ->

         it 'should accept a non-negative integer parameter', () ->
            j = job.repeat 3
            assert.equal j, job
            assert.equal doc.repeats, 3

         it 'should accept an option object', () ->
            j = job.repeat { repeats: 3, until: new Date(new Date().valueOf() + 60000), wait: 5000 }
            assert.equal j, job
            assert.equal doc.repeats, 3
            assert.ok(doc.repeatUntil > new Date())
            assert.equal doc.repeatWait, 5000

         it 'should accept an option object with later.js object', () ->
            j = job.repeat { schedule: { schedules: [{h:[10]}], exceptions: [], other: () -> 0 }}
            assert.equal j, job
            assert.deepEqual doc.repeatWait, { schedules: [{h:[10]}], exceptions: [] }

         it 'should throw when given a bad parameter', () ->
            assert.throw (() -> job.repeat 'badness'), /bad parameter: accepts either an integer/

         it 'should throw when given a negative integer', () ->
            assert.throw (() -> job.repeat -1), /bad parameter: accepts either an integer/

         it 'should throw when given a numeric non-integer', () ->
            assert.throw (() -> job.repeat 3.14), /bad parameter: accepts either an integer/

         it 'should throw when given bad options', () ->
            assert.throw (() -> job.repeat { repeats: 'badness' }), /bad option: repeats must be an integer/
            assert.throw (() -> job.repeat { repeats: -1 }), /bad option: repeats must be an integer/
            assert.throw (() -> job.repeat { repeats: 3.14 }), /bad option: repeats must be an integer/
            assert.throw (() -> job.repeat { wait: 'badness' }), /bad option: wait must be an integer/
            assert.throw (() -> job.repeat { wait: -1 }), /bad option: wait must be an integer/
            assert.throw (() -> job.repeat { wait: 3.14 }), /bad option: wait must be an integer/
            assert.throw (() -> job.repeat { until: 'bogus' }), /bad option: until must be a Date object/
            assert.throw (() -> job.repeat { wait: 5, schedule: {}}), /bad options: wait and schedule options are mutually exclusive/
            assert.throw (() -> job.repeat { schedule: 'bogus' }), /bad option, schedule option must be an object/
            assert.throw (() -> job.repeat { schedule: {}}), /bad option, schedule object requires a schedules attribute of type Array/
            assert.throw (() -> job.repeat { schedule: { schedules: 5 }}), /bad option, schedule object requires a schedules attribute of type Array/
            assert.throw (() -> job.repeat { schedule: { schedules: [], exceptions: 5 }}), /bad option, schedule object exceptions attribute must be an Array/

      describe '.after()', () ->

         it 'should accept a valid Date', () ->
            d = new Date()
            j = job.after d
            assert.equal j, job
            assert.equal doc.after, d

         it 'should accept an undefined value', () ->
            j = job.after()
            assert.equal j, job
            assert.instanceOf doc.after, Date
            assert doc.after <= new Date()

         it 'should throw if given a bad parameter', () ->
            assert.throw (() -> job.after { foo: "bar" }), /Bad parameter, after requires a valid Date object/
            assert.throw (() -> job.after 123), /Bad parameter, after requires a valid Date object/
            assert.throw (() -> job.after false), /Bad parameter, after requires a valid Date object/

      describe '.delay()', () ->

         it 'should accept a valid delay', () ->
            j = job.delay 5000
            assert.equal j, job
            assert.instanceOf doc.after, Date
            assert.closeTo doc.after.valueOf(), new Date().valueOf() + 5000, 1000

         it 'should accept an undefined parameter', () ->
            j = job.delay()
            assert.equal j, job
            assert.instanceOf doc.after, Date
            assert.closeTo doc.after.valueOf(), new Date().valueOf(), 1000

         it 'should throw when given an invalid parameter', () ->
            assert.throw (() -> job.delay -1.234), /Bad parameter, delay requires a non-negative integer/
            assert.throw (() -> job.delay new Date()), /Bad parameter, delay requires a non-negative integer/
            assert.throw (() -> job.delay false), /Bad parameter, delay requires a non-negative integer/

   describe 'communicating', () ->

      ddp = null

      before () ->
         ddp = new DDP()
         Job.setDDP ddp

      describe 'job status method', () ->

         job = null
         doc = null

         beforeEach () ->
            job = Job('root', 'work', {})
            doc = job._doc

         describe '.save()', () ->

            before () ->
               sinon.stub Job, "_ddp_apply", makeDdpStub (name, params) ->
                  throw new Error 'Bad method name' unless name is 'root_jobSave'
                  doc = params[0]
                  options = params[1]
                  if options.cancelRepeats
                     throw new Error 'cancelRepeats'
                  if typeof doc is 'object'
                     res = "newId"
                  else
                     res = null
                  return [null, res]

            it 'should make valid DDP call when invoked', () ->
               res = job.save()
               assert.equal res, "newId"

            it 'should work with a callback', (done) ->
               job.save (err, res) ->
                  assert.equal res, "newId"
                  done()

            it 'should properly pass cancelRepeats option', () ->
               assert.throw (() -> job.save({ cancelRepeats: true })), /cancelRepeats/

            it 'should properly pass cancelRepeats option with callback', () ->
               assert.throw (() -> job.save({ cancelRepeats: true }, () -> )), /cancelRepeats/

            afterEach () ->
               Job._ddp_apply.reset()

            after () ->
               Job._ddp_apply.restore()

         describe '.refresh()', () ->

            before () ->
               sinon.stub Job, "_ddp_apply", makeDdpStub (name, params) ->
                  throw new Error 'Bad method name' unless name is 'root_getJob'
                  id = params[0]
                  options = params[1]
                  if options.getLog
                     throw new Error 'getLog'
                  if id is 'thisId'
                     res = { foo: 'bar' }
                  else
                     res = null
                  return [null, res]

            it 'should make valid DDP call when invoked', () ->
               doc._id = 'thisId'
               res = job.refresh()
               assert.deepEqual job._doc, { foo: 'bar' }
               assert.equal res, job

            it 'should work with a callback', (done) ->
               doc._id = 'thisId'
               job.refresh (err, res) ->
                  assert.deepEqual job._doc, { foo: 'bar' }
                  assert.equal res, job
                  done()

            it "shouldn't modify job when not found on server", () ->
               doc._id = 'thatId'
               res = job.refresh()
               assert.isFalse res
               assert.deepEqual job._doc, doc

            it 'should properly pass getLog option', () ->
               doc._id = 'thisId'
               assert.throw (() -> job.refresh({ getLog: true })), /getLog/

            it 'should throw when called on an unsaved job', () ->
               assert.throw (() -> job.refresh()), /on an unsaved job/

            afterEach () ->
               Job._ddp_apply.reset()

            after () ->
               Job._ddp_apply.restore()

         describe '.log()', () ->

            before () ->
               sinon.stub Job, "_ddp_apply", makeDdpStub (name, params) ->
                  throw new Error 'Bad method name' unless name is 'root_jobLog'
                  id = params[0]
                  runId = params[1]
                  msg = params[2]
                  level = params[3]?.level ? 'gerinfo'
                  if id is 'thisId' and runId is 'thatId' and msg is 'Hello' and level in Job.jobLogLevels
                     res = level
                  else
                     res = false
                  return [null, res]

            it 'should add a valid log entry to the local state when invoked before a job is saved', () ->
               j = job.log 'Hello', { level: 'success' }
               assert.equal j, job
               thisLog = doc.log[1] #  [0] is the 'Created' log message
               assert.equal thisLog.message, 'Hello'
               assert.equal thisLog.level, 'success'
               assert.instanceOf thisLog.time, Date
               assert.closeTo thisLog.time.valueOf(), new Date().valueOf(), 1000

            it 'should make valid DDP call when invoked on a saved job', () ->
               doc._id = 'thisId'
               doc.runId = 'thatId'
               res = job.log 'Hello'
               assert.equal res, 'info'

            it 'should correctly pass level option', () ->
               doc._id = 'thisId'
               doc.runId = 'thatId'
               res = job.log 'Hello', { level: 'danger' }
               assert.equal res, 'danger'

            it 'should work with a callback', (done) ->
               doc._id = 'thisId'
               doc.runId = 'thatId'
               job.log 'Hello', { level: 'success' }, (err, res) ->
                  assert.equal res, 'success'
                  done()

            it 'should throw when passed an invalid message', () ->
               doc._id = 'thisId'
               doc.runId = 'thatId'
               assert.throw (() -> job.log 43, { level: 'danger' }), /Log message must be a string/

            it 'should throw when passed an invalid level', () ->
               doc._id = 'thisId'
               doc.runId = 'thatId'
               assert.throw (() -> job.log 'Hello', { level: 'blargh' }), /Log level options must be one of Job.jobLogLevels/
               assert.throw (() -> job.log 'Hello', { level: [] }), /Log level options must be one of Job.jobLogLevels/

            describe 'echo option', () ->

               jobConsole = null

               before () ->
                  jobConsole = Job.__get__ 'console'
                  Job.__set__ 'console',
                     info: (params...) -> throw new Error 'info'
                     log: (params...) -> throw new Error 'success'
                     warn: (params...) -> throw new Error 'warning'
                     error: (params...) -> throw new Error 'danger'

               it 'should echo the log to the console at the level requested', () ->
                  assert.doesNotThrow (() -> job.log 'Hello'), 'echo occurred without being requested'
                  assert.doesNotThrow (() -> job.log 'Hello', { echo: false }), 'echo occurred when explicitly disabled'
                  assert.throw (() -> job.log 'Hello', { echo: true }), /info/
                  assert.throw (() -> job.log 'Hello', { echo: true, level: 'info' }), /info/
                  assert.throw (() -> job.log 'Hello', { echo: true, level: 'success' }), /success/
                  assert.throw (() -> job.log 'Hello', { echo: true, level: 'warning' }), /warning/
                  assert.throw (() -> job.log 'Hello', { echo: true, level: 'danger' }), /danger/

               it "shouldn't echo the log to the console below the level requested", () ->
                  assert.doesNotThrow (() -> job.log 'Hello', { echo: 'warning' })
                  assert.doesNotThrow (() -> job.log 'Hello', { echo: 'warning', level: 'info' })
                  assert.doesNotThrow (() -> job.log 'Hello', { echo: 'warning', level: 'success' })
                  assert.throw (() -> job.log 'Hello', { echo: 'warning', level: 'warning' }), /warning/
                  assert.throw (() -> job.log 'Hello', { echo: 'warning', level: 'danger' }), /danger/

               after () ->
                  Job.__set__ 'console', jobConsole

            afterEach () ->
               Job._ddp_apply.reset()

            after () ->
               Job._ddp_apply.restore()

         describe '.progress()', () ->

            before () ->
               sinon.stub Job, "_ddp_apply", makeDdpStub (name, params) ->
                  throw new Error 'Bad method name' unless name is 'root_jobProgress'
                  id = params[0]
                  runId = params[1]
                  completed = params[2]
                  total = params[3]
                  if ( id is 'thisId' and
                       runId is 'thatId' and
                       typeof completed is 'number' and
                       typeof total is 'number' and
                       0 <= completed <= total and
                       total > 0 )
                     res = 100 * completed / total
                  else
                     res = false
                  return [null, res]

            it 'should add a valid progress update to the local state when invoked before a job is saved', () ->
               j = job.progress 2.5, 10
               assert.equal j, job
               assert.deepEqual doc.progress, { completed: 2.5, total: 10, percent: 25 }

            it 'should make valid DDP call when invoked on a saved job', () ->
               doc._id = 'thisId'
               doc.runId = 'thatId'
               res = job.progress 5, 10
               assert.equal res, 50

            it 'should work with a callback', (done) ->
               doc._id = 'thisId'
               doc.runId = 'thatId'
               job.progress 7.5, 10, (err, res) ->
                  assert.equal res, 75
                  done()

            describe 'echo option', () ->

               jobConsole = null

               before () ->
                  jobConsole = Job.__get__ 'console'
                  Job.__set__ 'console',
                     info: (params...) -> throw new Error 'info'

               it 'should progress updates to the console when requested', () ->
                  assert.doesNotThrow (() -> job.progress 0, 100)
                  assert.doesNotThrow (() -> job.progress 0, 100, { echo: false })
                  assert.throw (() -> job.progress 0, 100, { echo: true }), /info/

               after () ->
                  Job.__set__ 'console', jobConsole

            it 'should throw when given invalid paramters', () ->
               assert.throw (() -> job.progress true, 100), /job.progress: something is wrong with progress params/
               assert.throw (() -> job.progress 0, "hundred"), /job.progress: something is wrong with progress params/
               assert.throw (() -> job.progress -1, 100), /job.progress: something is wrong with progress params/
               assert.throw (() -> job.progress 2, 1), /job.progress: something is wrong with progress params/
               assert.throw (() -> job.progress 0, 0), /job.progress: something is wrong with progress params/
               assert.throw (() -> job.progress 0, -1), /job.progress: something is wrong with progress params/
               assert.throw (() -> job.progress -2, -1), /job.progress: something is wrong with progress params/

            afterEach () ->
               Job._ddp_apply.reset()

            after () ->
               Job._ddp_apply.restore()

         describe '.done()', () ->

            before () ->
               sinon.stub Job, "_ddp_apply", makeDdpStub (name, params) ->
                  throw new Error 'Bad method name' unless name is 'root_jobDone'
                  id = params[0]
                  runId = params[1]
                  result = params[2]
                  options = params[3]
                  if ( id is 'thisId' and
                       runId is 'thatId' and
                       typeof result is 'object')
                     res = result
                  else if options.resultId
                     res = result.resultId
                  else
                     res = false
                  return [null, res]

            it 'should make valid DDP call when invoked on a running job', () ->
               doc._id = 'thisId'
               doc.runId = 'thatId'
               res = job.done()
               assert.deepEqual res, {}

            it 'should properly handle a result object', () ->
               doc._id = 'thisId'
               doc.runId = 'thatId'
               result =
                  foo: 'bar'
                  status: 0
               res = job.done result
               assert.deepEqual res, result

            it 'should properly handle a non-object result', () ->
               doc._id = 'thisId'
               doc.runId = 'thatId'
               result = "Done!"
               res = job.done result
               assert.deepEqual res, { value: result }

            it 'should work with a callback', (done) ->
               doc._id = 'thisId'
               doc.runId = 'thatId'
               job.done (err, res) ->
                  assert.deepEqual res, {}
                  done()

            it 'should throw when called on an unsaved job', () ->
               assert.throw (() -> job.done()), /an unsaved or non-running job/

            it 'should throw when called on a nonrunning job', () ->
               doc._id = 'thisId'
               assert.throw (() -> job.done()), /an unsaved or non-running job/

            it 'should properly pass the repeatId option', () ->
               doc._id = 'someId'
               doc.runId = 'otherId'
               job.done { repeatId: "testID" }, { repeatId: true }, (err, res) ->
                  assert.deepEqual res, "testID"
                  done()

            afterEach () ->
               Job._ddp_apply.reset()

            after () ->
               Job._ddp_apply.restore()

         describe '.fail()', () ->

            before () ->
               sinon.stub Job, "_ddp_apply", makeDdpStub (name, params) ->
                  throw new Error 'Bad method name' unless name is 'root_jobFail'
                  id = params[0]
                  runId = params[1]
                  err = params[2]
                  options = params[3]
                  if ( id is 'thisId' and
                       runId is 'thatId' and
                       typeof err is 'object')
                     if options.fatal
                        throw new Error "Fatal Error!"
                     res = err
                  else
                     res = false
                  return [null, res]

            it 'should make valid DDP call when invoked on a running job', () ->
               doc._id = 'thisId'
               doc.runId = 'thatId'
               res = job.fail()
               assert.deepEqual res, { value: "No error information provided" }

            it 'should properly handle an error string', () ->
               doc._id = 'thisId'
               doc.runId = 'thatId'
               err = 'This is an error'
               res = job.fail err
               assert.deepEqual res, { value: err }

            it 'should properly handle an error object', () ->
               doc._id = 'thisId'
               doc.runId = 'thatId'
               err = { message: 'This is an error' }
               res = job.fail err
               assert.equal res, err

            it 'should work with a callback', (done) ->
               doc._id = 'thisId'
               doc.runId = 'thatId'
               job.fail (err, res) ->
                  assert.equal res.value, "No error information provided"
                  done()

            it 'should properly handle the fatal option', () ->
               doc._id = 'thisId'
               doc.runId = 'thatId'
               assert.throw (() -> job.fail "Fatal error!", { fatal: true }), /Fatal Error!/

            it 'should throw when called on an unsaved job', () ->
               assert.throw (() -> job.fail()), /an unsaved or non-running job/

            it 'should throw when called on a nonrunning job', () ->
               doc._id = 'thisId'
               assert.throw (() -> job.fail()), /an unsaved or non-running job/

            afterEach () ->
               Job._ddp_apply.reset()

            after () ->
               Job._ddp_apply.restore()

         describe 'job control operation', () ->

            makeJobControl = (op, method) ->

               describe op, () ->

                  before () ->
                     sinon.stub Job, "_ddp_apply", makeDdpStub (name, params) ->
                        throw new Error "Bad method name: #{name}" unless name is "root_#{method}"
                        id = params[0]
                        if id is 'thisId'
                           res = true
                        else
                           res = false
                        return [null, res]

                  it 'should properly invoke the DDP method', () ->
                     assert.isFunction job[op]
                     doc._id = 'thisId'
                     res = job[op]()
                     assert.isTrue res

                  it 'should return false if the id is not on the server', () ->
                     assert.isFunction job[op]
                     doc._id = 'badId'
                     res = job[op]()
                     assert.isFalse res

                  it 'should work with a callback', (done) ->
                     assert.isFunction job[op]
                     doc._id = 'thisId'
                     res = job[op] (err, res) ->
                        assert.isTrue res
                        done()

                  if op in ['pause', 'resume']
                     it 'should alter local state when called on an unsaved job', () ->
                        bad = 'badStatus'
                        doc.status = bad
                        res = job[op]()
                        assert.equal res, job
                        assert.notEqual doc.status, bad

                     it 'should alter local state when called on an unsaved job with callback', (done) ->
                        bad = 'badStatus'
                        doc.status = bad
                        res = job[op] (err, res) ->
                           assert.isTrue res
                           assert.notEqual doc.status, bad
                           done()
                  else
                     it 'should throw when called on an unsaved job', () ->
                        assert.throw (() -> job[op]()), /on an unsaved job/

                  afterEach () ->
                     Job._ddp_apply.reset()

                  after () ->
                     Job._ddp_apply.restore()

            makeJobControl 'pause', 'jobPause'
            makeJobControl 'resume', 'jobResume'
            makeJobControl 'ready', 'jobReady'
            makeJobControl 'cancel', 'jobCancel'
            makeJobControl 'restart', 'jobRestart'
            makeJobControl 'rerun', 'jobRerun'
            makeJobControl 'remove', 'jobRemove'

      describe 'class method', () ->

         describe 'getWork', () ->

            before () ->
               sinon.stub Job, "_ddp_apply", makeDdpStub (name, params) ->
                  throw new Error 'Bad method name' unless name is 'root_getWork'
                  type = params[0][0]
                  max = params[1]?.maxJobs ? 1
                  res = switch type
                     when 'work'
                        ( Job('root', type, { i: 1 })._doc for i in [1..max] )
                     when 'nowork'
                        []
                  return [null, res]

            it 'should make a DDP method call and return a Job by default without callback', () ->
               res = Job.getWork 'root', 'work', {}
               assert.instanceOf res, Job

            it 'should return undefined when no work is available without callback', () ->
               res = Job.getWork 'root', 'nowork', {}
               assert.isUndefined res

            it 'should return an array of Jobs when options.maxJobs > 1 without callback', () ->
               res = Job.getWork 'root', 'work', { maxJobs: 2 }
               assert.isArray res
               assert.lengthOf res, 2
               assert.instanceOf res[0], Job

            it 'should return an empty array when options.maxJobs > 1 and there is no work without callback', () ->
               res = Job.getWork 'root', 'nowork', { maxJobs: 2 }
               assert.isArray res
               assert.lengthOf res, 0

            it 'should throw when given on invalid value for the timeout option', () ->
               assert.throw (() -> Job.getWork('root', 'nowork', { workTimeout: "Bad" })), /must be a positive integer/
               assert.throw (() -> Job.getWork('root', 'nowork', { workTimeout: 0 })), /must be a positive integer/
               assert.throw (() -> Job.getWork('root', 'nowork', { workTimeout: -1 })), /must be a positive integer/

            afterEach () ->
               Job._ddp_apply.reset()

            after () ->
               Job._ddp_apply.restore()

         describe 'makeJob', () ->

            jobDoc = () ->
               j = new Job('root', 'work', {})._doc
               j._id = { _str: 'skljfdf9s0ujfsdfl3' }
               return j

            it 'should return a valid job instance when called with a valid job document', () ->
               res = new Job 'root', jobDoc()
               assert.instanceOf res, Job

            it 'should throw when passed invalid params', () ->
               assert.throw (() -> new Job()), /bad parameter/
               assert.throw (() -> new Job(5, jobDoc())), /bad parameter/
               assert.throw (() -> new Job('work', {})), /bad parameter/

         describe 'get Job(s) by ID', () ->

            getJobStub = (name, params) ->
               throw new Error 'Bad method name' unless name is 'root_getJob'
               ids = params[0]

               one = (id) ->
                  j = switch id
                     when 'goodID'
                        Job('root', 'work', { i: 1 })._doc
                     else
                        undefined
                  return j

               if ids instanceof Array
                  res = (one(j) for j in ids when j is 'goodID')
               else
                  res = one(ids)

               return [null, res]

            describe 'getJob', () ->

               before () ->
                  sinon.stub Job, "_ddp_apply", makeDdpStub getJobStub

               it 'should return a valid job instance when called with a good id', () ->
                  res = Job.getJob 'root', 'goodID'
                  assert.instanceOf res, Job

               it 'should return undefined when called with a bad id', () ->
                  res = Job.getJob 'root', 'badID'
                  assert.isUndefined res

               afterEach () ->
                  Job._ddp_apply.reset()

               after () ->
                  Job._ddp_apply.restore()

            describe 'getJobs', () ->

               before () ->
                  sinon.stub Job, "_ddp_apply", makeDdpStub getJobStub

               it 'should return valid job instances for good IDs only', () ->
                  res = Job.getJobs 'root', ['goodID', 'badID', 'goodID']
                  assert Job._ddp_apply.calledOnce, 'getJob method called more than once'
                  assert.isArray res
                  assert.lengthOf res, 2
                  assert.instanceOf res[0], Job
                  assert.instanceOf res[1], Job

               it 'should return an empty array for all bad IDs', () ->
                  res = Job.getJobs 'root', ['badID', 'badID', 'badID']
                  assert Job._ddp_apply.calledOnce, 'getJob method called more than once'
                  assert.isArray res
                  assert.lengthOf res, 0

               afterEach () ->
                  Job._ddp_apply.reset()

               after () ->
                  Job._ddp_apply.restore()

         describe 'multijob operation', () ->

            makeMulti = (op, method) ->

               describe op, () ->

                  before () ->
                     sinon.stub Job, "_ddp_apply", makeDdpStub (name, params) ->
                        throw new Error "Bad method name: #{name}" unless name is "root_#{method}"
                        ids = params[0]
                        return [null, ids.indexOf('goodID') isnt -1]

                  it 'should return true if there are any good IDs', () ->
                     assert.isFunction Job[op]
                     res = Job[op]('root', ['goodID', 'badID', 'goodID'])
                     assert Job._ddp_apply.calledOnce, "#{op} method called more than once"
                     assert.isBoolean res
                     assert.isTrue res

                  it 'should return false if there are all bad IDs', () ->
                     assert.isFunction Job[op]
                     res = Job[op]('root', ['badID', 'badID'])
                     assert Job._ddp_apply.calledOnce, "#{op} method called more than once"
                     assert.isBoolean res
                     assert.isFalse res

                  afterEach () ->
                     Job._ddp_apply.reset()

                  after () ->
                     Job._ddp_apply.restore()

            makeMulti 'pauseJobs', 'jobPause'
            makeMulti 'resumeJobs', 'jobResume'
            makeMulti 'cancelJobs', 'jobCancel'
            makeMulti 'restartJobs', 'jobRestart'
            makeMulti 'removeJobs', 'jobRemove'

         describe 'control method', () ->

            makeControl = (op) ->

               describe op, () ->

                  before () ->
                     sinon.stub Job, "_ddp_apply", makeDdpStub (name, params) ->
                        throw new Error "Bad method name: #{name}" unless name is "root_#{op}"
                        return [null, true]

                  it 'should return a boolean', () ->
                     assert.isFunction Job[op]
                     res = Job[op]('root')
                     assert Job._ddp_apply.calledOnce, "#{op} method called more than once"
                     assert.isBoolean res

                  afterEach () ->
                     Job._ddp_apply.reset()

                  after () ->
                     Job._ddp_apply.restore()

            makeControl 'startJobs'
            makeControl 'stopJobs'
            makeControl 'startJobServer'
            makeControl 'shutdownJobServer'

###########################################

describe 'JobQueue', () ->

   ddp = new DDP()
   failCalls = 0
   doneCalls = 0
   numJobs = 5

   before () ->
      Job._ddp_apply = undefined
      Job.setDDP ddp
      sinon.stub Job, "_ddp_apply", makeDdpStub (name, params) ->
         # console.log "#{name} Called"
         err = null
         res = null
         makeJobDoc = (idx=0) ->
            job = new Job('root', 'work', { idx: idx })
            doc = job._doc
            doc._id = 'thisId' + idx
            doc.runId = 'thatId' + idx
            doc.status = 'running'
            return doc
         switch name
            when 'root_jobDone'
               doneCalls++
               res = true
            when 'root_jobFail'
               failCalls++
               res = true
            when 'root_getWork'
               type = params[0][0]
               max = params[1]?.maxJobs ? 1
               if numJobs is 0
                  res = []
               else
                  switch type
                     when 'noWork'
                        res = []
                     when 'work'
                        numJobs--
                        res = [ makeJobDoc() ]
                     when 'workMax'
                        if max < numJobs
                           max = numJobs
                        numJobs -= max
                        res = (makeJobDoc(i) for i in [1..max])
            else
               throw new Error "Bad method name: #{name}"
         return [err, res]

   beforeEach () ->
      failCalls = 0
      doneCalls = 0
      numJobs = 5

   it 'should throw when an invalid options are used', (done) ->
     assert.throws (() ->
       Job.processJobs 'root', 'noWork', { pollInterval: -1 }, (job, cb) -> ),
       /must be a positive integer/
     assert.throws (() ->
       Job.processJobs 'root', 'noWork', { concurrency: 'Bad' }, (job, cb) -> ),
       /must be a positive integer/
     assert.throws (() ->
       Job.processJobs 'root', 'noWork', { concurrency: -1 }, (job, cb) -> ),
       /must be a positive integer/
     assert.throws (() ->
       Job.processJobs 'root', 'noWork', { payload: 'Bad' }, (job, cb) -> ),
       /must be a positive integer/
     assert.throws (() ->
       Job.processJobs 'root', 'noWork', { payload: -1 }, (job, cb) -> ),
       /must be a positive integer/
     assert.throws (() ->
       Job.processJobs 'root', 'noWork', { prefetch: 'Bad' }, (job, cb) -> ),
       /must be a positive integer/
     assert.throws (() ->
       Job.processJobs 'root', 'noWork', { prefetch: -1 }, (job, cb) -> ),
       /must be a positive integer/
     assert.throws (() ->
       Job.processJobs 'root', 'noWork', { workTimeout: 'Bad' }, (job, cb) -> ),
       /must be a positive integer/
     assert.throws (() ->
       Job.processJobs 'root', 'noWork', { workTimeout: -1 }, (job, cb) -> ),
       /must be a positive integer/
     done()

   it 'should return a valid JobQueue when called', (done) ->
      q = Job.processJobs 'root', 'noWork', { pollInterval: 100 }, (job, cb) ->
         job.done()
         cb null
      assert.instanceOf q, Job.processJobs
      q.shutdown { quiet: true }, () ->
         assert.equal doneCalls, 0
         assert.equal failCalls, 0
         done()

   it 'should send shutdown notice to console when quiet is false', (done) ->
      jobConsole = Job.__get__ 'console'
      revert = Job.__set__
         console:
            info: (params...) -> throw new Error 'info'
            log: (params...) -> throw new Error 'success'
            warn: (params...) -> throw new Error 'warning'
            error: (params...) -> throw new Error 'danger'
      q = Job.processJobs 'root', 'noWork', { pollInterval: 100 }, (job, cb) ->
         job.done()
         cb null
      assert.instanceOf q, Job.processJobs
      assert.throws (() -> (q.shutdown () -> done())), /warning/
      revert()
      q.shutdown { quiet: true }, () ->
         assert.equal doneCalls, 0
         assert.equal failCalls, 0
         done()

   it 'should invoke worker when work is returned', (done) ->
      q = Job.processJobs 'root', 'work', { pollInterval: 100 }, (job, cb) ->
         job.done()
         q.shutdown { quiet: true }, () ->
            assert.equal doneCalls, 1
            assert.equal failCalls, 0
            done()
         cb null

   it 'should invoke worker when work is returned from a manual trigger', (done) ->
      q = Job.processJobs 'root', 'work', { pollInterval: 0 }, (job, cb) ->
         job.done()
         q.shutdown { quiet: true }, () ->
            assert.equal doneCalls, 1
            assert.equal failCalls, 0
            done()
         cb null
      assert.equal q.pollInterval, Job.forever
      assert.isNull q._interval
      setTimeout(
         () -> q.trigger()
         20
      )

   it 'should successfully start in paused state and resume', (done) ->
      flag = false
      q = Job.processJobs('root', 'work', { pollInterval: 10 }, (job, cb) ->
         assert.isTrue flag
         job.done()
         q.shutdown { quiet: true }, () ->
            assert.equal doneCalls, 1
            assert.equal failCalls, 0
            done()
         cb null
      ).pause()
      setTimeout(
         () ->
            flag = true
            q.resume()
         20
      )

   it 'should successfully accept multiple jobs from getWork', (done) ->
      count = 5
      q = Job.processJobs('root', 'workMax', { pollInterval: 100, prefetch: 4 }, (job, cb) ->
         assert.equal q.length(), count-1, 'q.length is incorrect'
         assert.equal q.running(), 1, 'q.running is incorrect'
         if count is 5
            assert.isTrue q.full(), 'q.full should be true'
            assert.isFalse q.idle(), 'q.idle should be false'
         job.done()
         count--
         if count is 0
            q.shutdown { quiet: true }, () ->
               assert.equal doneCalls, 5, 'doneCalls is incorrect'
               assert.equal failCalls, 0, 'failCalls is incorrect'
               done()
         cb null
      )

   it 'should successfully accept and process multiple simultaneous jobs concurrently', (done) ->
      count = 0
      q = Job.processJobs('root', 'workMax', { pollInterval: 100, concurrency: 5 }, (job, cb) ->
         count++
         setTimeout(
            () ->
               assert.equal q.length(), 0
               assert.equal q.running(), count
               count--
               job.done()
               unless count > 0
                  q.shutdown { quiet: true }, () ->
                     assert.equal doneCalls, 5
                     assert.equal failCalls, 0
                     done()
               cb null
            25
         )
      )

   it 'should successfully accept and process multiple simultaneous jobs in one worker', (done) ->
      q = Job.processJobs('root', 'workMax', { pollInterval: 100, payload: 5 }, (jobs, cb) ->
         assert.equal jobs.length, 5
         assert.equal q.length(), 0
         assert.equal q.running(), 1
         j.done() for j in jobs
         q.shutdown { quiet: true }, () ->
            assert.equal doneCalls, 5
            assert.equal failCalls, 0
            done()
         cb()
      )

   it 'should successfully accept and process multiple simultaneous jobs concurrently and within workers', (done) ->
      count = 0
      numJobs = 25
      q = Job.processJobs('root', 'workMax', { pollInterval: 100, payload: 5, concurrency: 5 }, (jobs, cb) ->
         count += jobs.length
         setTimeout(
            () ->
               assert.equal q.length(), 0
               assert.equal q.running(), count / 5
               count -= jobs.length
               j.done() for j in jobs
               unless count > 0
                  q.shutdown { quiet: true }, () ->
                     assert.equal doneCalls, 25
                     assert.equal failCalls, 0
                     done()
               cb null
            25
         )
      )

   it 'should successfully perform a soft shutdown', (done) ->
      count = 5
      q = Job.processJobs('root', 'workMax', { pollInterval: 100, prefetch: 4 }, (job, cb) ->
         count--
         assert.equal q.length(), count
         assert.equal q.running(), 1
         assert.isTrue q.full()
         job.done()
         if count is 4
            q.shutdown { quiet: true, level: 'soft' }, () ->
               assert count is 0
               assert.equal q.length(), 0
               assert.isFalse Job._ddp_apply.calledWith("root_jobFail")
               assert.equal doneCalls, 5
               assert.equal failCalls, 0
               done()
         cb null
      )

   it 'should successfully perform a normal shutdown', (done) ->
      count = 5
      q = Job.processJobs('root', 'workMax', { pollInterval: 100, concurrency: 2, prefetch: 3 }, (job, cb) ->
         setTimeout(
            () ->
               count--
               job.done()
               if count is 4
                  q.shutdown { quiet: true, level: 'normal' }, () ->
                     assert.equal count, 3
                     assert.equal q.length(), 0
                     assert.isTrue Job._ddp_apply.calledWith("root_jobFail")
                     assert.equal doneCalls, 2
                     assert.equal failCalls, 3
                     done()
               cb null
            25
         )
      )


   it 'should successfully perform a normal shutdown with both payload and concurrency', (done) ->
      count = 0
      numJobs = 25
      q = Job.processJobs('root', 'workMax', { pollInterval: 100, payload: 5, concurrency: 2, prefetch: 15 }, (jobs, cb) ->
         count += jobs.length
         setTimeout(
            () ->
               assert.equal q.running(), count / 5
               count -= jobs.length
               j.done() for j in jobs
               if count is 5
                  q.shutdown { quiet: true }, () ->
                     assert.equal q.length(), 0, 'jobs remain in task list'
                     assert.equal count, 0, 'count is wrong value'
                     assert.isTrue Job._ddp_apply.calledWith("root_jobFail")
                     assert.equal doneCalls, 10
                     assert.equal failCalls, 15
                     done()
               cb null
            25
         )
      )

   it 'should successfully perform a hard shutdown', (done) ->
      count = 0
      time = 20
      q = Job.processJobs('root', 'workMax', { pollInterval: 100, concurrency: 2, prefetch: 3 }, (job, cb) ->
         setTimeout(
            () ->
               job.done()
               count++
               if count is 1
                  q.shutdown { quiet: true, level: 'hard' }, () ->
                     assert.equal q.length(), 0
                     assert.equal count, 1
                     assert.isTrue Job._ddp_apply.calledWith("root_jobFail")
                     assert.equal doneCalls, 1, 'wrong number of .done() calls'
                     assert.equal failCalls, 4, 'wrong number of .fail() calls'
                     done()
                  cb null  # Other workers will never call back
            time
         )
         time += 20
      )

   afterEach () ->
      Job._ddp_apply.reset()

   after () ->
      Job._ddp_apply.restore()
