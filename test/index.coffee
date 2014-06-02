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

      describe 'callbackGenerator', () ->
         callbackGenerator = Job.__get__ 'callbackGenerator'

         it 'should return undefined if given a falsy callback', () ->
            assert.isUndefined callbackGenerator(undefined, 5)

         it 'should properly absorb the specified number of callbacks', () ->
            spy = sinon.spy()
            cb = callbackGenerator spy, 3
            cb null, true
            cb null, false
            cb null, true
            assert spy.calledOnce
            assert spy.calledWith null, true

         it 'should properly reduce the ballback results', () ->
            spy = sinon.spy()
            cb = callbackGenerator spy, 3
            cb null, false
            cb null, false
            cb null, false
            assert spy.calledOnce
            assert spy.calledWith null, false

         it 'should throw if called too many times', () ->
            spy = sinon.spy()
            cb = callbackGenerator spy, 2
            cb null, true
            cb null, true
            assert.throws cb, /callbackGenerator callback invoked more than requested/

         it 'should throw if given a non-function callback', () ->
            assert.throws (() -> callbackGenerator 5), /Bad params given to callbackGenerator/

         it 'should throw if given an invalid number of callbacks to absorb', () ->
            assert.throws (() -> callbackGenerator (() -> ), 'cow'), /Bad params given to callbackGenerator/

         it 'should throw if given an out of range number of callbacks to absorb', () ->
            assert.throws (() -> callbackGenerator (() -> ), 0), /Bad params given to callbackGenerator/


# describe 'ddp-login', () ->

#    describe 'API', () ->

#       it 'should throw when invoked without a valid callback', () ->
#          assert.throws login, /Valid callback must be provided to ddp-login/

#       it 'should require a valid ddp parameter', () ->
#          login null, (e) ->
#             assert.throws (() -> throw e), /Invalid DDP parameter/

#       it 'should reject unsupported login methods', () ->
#          login { loginWithToken: () -> }, { method: 'bogus' }, (e) ->
#             assert.throws (() -> throw e), /Unsupported DDP login method/

#       describe 'authToken handling', () ->

#          it 'should return an existing valid authToken in the default environment variable', (done) ->
#             process.env.METEOR_TOKEN = goodToken
#             login ddp, (e, token) ->
#                assert.ifError e
#                assert.equal token, goodToken, 'Wrong token returned'
#                process.env.METEOR_TOKEN = undefined
#                done()

#          it 'should return an existing valid authToken in a specified environment variable', (done) ->
#             process.env.TEST_TOKEN = goodToken
#             login ddp, { env: 'TEST_TOKEN' }, (e, token) ->
#                assert.ifError e
#                assert.equal token, goodToken, 'Wrong token returned'
#                process.env.TEST_TOKEN = undefined
#                done()

#       describe 'login with email', () ->

#          it 'should return a valid authToken when successful', (done) ->
#             pass = goodpass
#             login ddp, (e, token) ->
#                assert.ifError e
#                assert.equal token, goodToken, 'Wrong token returned'
#                done()

#          it 'should also work when method is set to email', (done) ->
#             pass = goodpass
#             login ddp, { method: 'email' }, (e, token) ->
#                assert.ifError e
#                assert.equal token, goodToken, 'Wrong token returned'
#                done()

#          it 'should retry 5 times by default and then fail with bad credentials', (done) ->
#             pass = badpass
#             sinon.spy ddp, 'loginWithEmail'
#             login ddp, (e, token) ->
#                assert.throws (() -> throw e), /Bad email credentials/
#                assert.equal ddp.loginWithEmail.callCount, 5
#                ddp.loginWithEmail.restore()
#                done()

#          it 'should retry the specified number of times and then fail with bad credentials', (done) ->
#             pass = badpass
#             sinon.spy ddp, 'loginWithEmail'
#             login ddp, { retry: 3 }, (e, token) ->
#                assert.throws (() -> throw e), /Bad email credentials/
#                assert.equal ddp.loginWithEmail.callCount, 3
#                ddp.loginWithEmail.restore()
#                done()

#          afterEach () ->
#             pass = null

#       describe 'login with username', () ->

#          it 'should return a valid authToken when successful', (done) ->
#             pass = goodpass
#             login ddp, { method: 'username' }, (e, token) ->
#                assert.ifError e
#                assert.equal token, goodToken, 'Wrong token returned'
#                done()

#          it 'should retry 5 times by default and then fail with bad credentials', (done) ->
#             pass = badpass
#             sinon.spy ddp, 'loginWithUsername'
#             login ddp, { method: 'username' }, (e, token) ->
#                assert.throws (() -> throw e), /Bad username credentials/
#                assert.equal ddp.loginWithUsername.callCount, 5
#                ddp.loginWithUsername.restore()
#                done()

#          it 'should retry the specified number of times and then fail with bad credentials', (done) ->
#             pass = badpass
#             sinon.spy ddp, 'loginWithUsername'
#             login ddp, { method: 'username', retry: 3 }, (e, token) ->
#                assert.throws (() -> throw e), /Bad username credentials/
#                assert.equal ddp.loginWithUsername.callCount, 3
#                ddp.loginWithUsername.restore()
#                done()

#          afterEach () ->
#             pass = null

#    describe 'Command line', () ->

#       newLogin = () ->
#          login = rewire '../src/index.coffee'
#          login.__set__ 'read', read
#          login.__set__ "DDP", DDP

#       beforeEach () -> newLogin()

#       it 'should support logging in with all default parameters', (done) ->
#          pass = goodpass
#          token = null
#          login.__set__
#             console:
#                log: (m) ->
#                   token = m
#                warn: console.warn
#          login.__set__ 'process.exit', (n) ->
#             assert.equal n, 0
#             assert.equal token, goodToken
#             done()
#          login._command_line()

#       it 'should fail logging in with bad credentials', (done) ->
#          pass = badpass
#          token = null
#          login.__set__
#             console:
#                log: (m) ->
#                   token = m
#                error: (m) ->
#                warn: console.warn
#                dir: (o) ->
#          login.__set__ 'process.exit', (n) ->
#             assert.equal n, 1
#             done()
#          login._command_line()

#       it 'should support logging in with username', (done) ->
#          pass = goodpass
#          token = null
#          login.__set__
#             console:
#                log: (m) ->
#                   token = m
#                warn: console.warn
#          login.__set__ 'process.exit', (n) ->
#             assert.equal n, 0
#             assert.equal token, goodToken
#             done()
#          login.__set__ 'process.argv', ['node', 'ddp-login', '--method', 'username']
#          login._command_line()

#       it 'should fail logging in with bad username credentials', (done) ->
#          pass = badpass
#          token = null
#          login.__set__
#             console:
#                log: (m) ->
#                   token = m
#                error: (m) ->
#                warn: console.warn
#                dir: (o) ->
#          login.__set__ 'process.exit', (n) ->
#             assert.equal n, 1
#             done()
#          login.__set__ 'process.argv', ['node', 'ddp-login', '--method', 'username']
#          login._command_line()

#       it 'should properly pass host and port to DDP', (done) ->
#          pass = goodpass
#          token = null
#          spyDDP = sinon.spy(DDP)
#          login.__set__ "DDP", spyDDP
#          login.__set__
#             console:
#                log: (m) ->
#                   token = m
#                warn: console.warn
#          login.__set__ 'process.exit', (n) ->
#             assert.equal n, 0
#             assert.equal token, goodToken
#             assert spyDDP.calledWithExactly
#                host: 'localhost'
#                port: 3333
#                use_ejson: true
#             done()
#          login.__set__ 'process.argv', ['node', 'ddp-login', '--host', 'localhost', '--port', '3333']
#          login._command_line()

#       it 'should succeed when a good token is in the default env var', (done) ->
#          pass = badpass
#          token = null
#          login.__set__ "DDP", DDP
#          login.__set__
#             console:
#                log: (m) ->
#                   token = m
#                warn: console.warn
#          login.__set__ 'process.exit', (n) ->
#             assert.equal n, 0, 'wrong return code'
#             assert.equal token, goodToken, 'Bad token'
#             done()
#          login.__set__ 'process.env.METEOR_TOKEN', goodToken
#          login._command_line()

#       it 'should succeed when a good token is in a specified env var', (done) ->
#          pass = badpass
#          token = null
#          login.__set__ "DDP", DDP
#          login.__set__
#             console:
#                log: (m) ->
#                   token = m
#                warn: console.warn
#          login.__set__ 'process.exit', (n) ->
#             assert.equal n, 0, 'wrong return code'
#             assert.equal token, goodToken, 'Bad token'
#             done()
#          login.__set__ 'process.env.TEST_TOKEN', goodToken
#          login.__set__ 'process.argv', ['node', 'ddp-login', '--env', 'TEST_TOKEN']
#          login._command_line()

#       it 'should succeed when a bad token is in a specified env var', (done) ->
#          pass = goodpass
#          token = null
#          login.__set__
#             console:
#                log: (m) ->
#                   token = m
#                warn: console.warn
#          login.__set__ 'process.exit', (n) ->
#             assert.equal n, 0, 'wrong return code'
#             assert.equal token, goodToken, 'Bad token'
#             done()
#          login.__set__ 'process.env.TEST_TOKEN', badToken
#          login.__set__ 'process.argv', ['node', 'ddp-login', '--env', 'TEST_TOKEN']
#          login._command_line()

#       it 'should retry 5 times by default', (done) ->
#          pass = badpass
#          token = null
#          sinon.spy DDP.prototype, 'loginWithEmail'
#          login.__set__
#             console:
#                log: (m) ->
#                   token = m
#                error: (m) ->
#                warn: console.warn
#                dir: (o) ->
#          login.__set__ 'process.exit', (n) ->
#             assert.equal n, 1
#             assert.equal DDP.prototype.loginWithEmail.callCount, 5
#             DDP.prototype.loginWithEmail.restore()
#             done()
#          login.__set__ 'process.env.TEST_TOKEN', badToken
#          login.__set__ 'process.argv', ['node', 'ddp-login', '--env', 'TEST_TOKEN']
#          login._command_line()

#       it 'should retry the specified number of times', (done) ->
#          pass = badpass
#          token = null
#          sinon.spy DDP.prototype, 'loginWithEmail'
#          login.__set__
#             console:
#                log: (m) ->
#                   token = m
#                error: (m) ->
#                warn: console.warn
#                dir: (o) ->
#          login.__set__ 'process.exit', (n) ->
#             assert.equal n, 1
#             assert.equal DDP.prototype.loginWithEmail.callCount, 3
#             DDP.prototype.loginWithEmail.restore()
#             done()
#          login.__set__ 'process.env.TEST_TOKEN', badToken
#          login.__set__ 'process.argv', ['node', 'ddp-login', '--env', 'TEST_TOKEN', '--retry', '3']
#          login._command_line()

#       afterEach () ->
#          pass = null
