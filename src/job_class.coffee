############################################################################
#     Copyright (C) 2014-2016 by Vaughn Iverson
#     meteor-job-class is free software released under the MIT/X11 license.
#     See included LICENSE file for details.
############################################################################

# Exports Job object

methodCall = (root, method, params, cb, after = ((ret) -> ret)) ->
  apply = Job._ddp_apply?[root.root ? root] ? Job._ddp_apply
  unless typeof apply is 'function'
     throw new Error "Job remote method call error, no valid invocation method found."
  name = "#{root.root ? root}_#{method}"
  if cb and typeof cb is 'function'
    apply name, params, (err, res) =>
      return cb err if err
      cb null, after(res)
  else
    return after(apply name, params)

optionsHelp = (options, cb) ->
  # If cb isn't a function, it's assumed to be options...
  if cb? and typeof cb isnt 'function'
    options = cb
    cb = undefined
  else
    unless (typeof options is 'object' and
            options instanceof Array and
            options.length < 2)
      throw new Error 'options... in optionsHelp must be an Array with zero or one elements'
    options = options?[0] ? {}
  unless typeof options is 'object'
    throw new Error 'in optionsHelp options not an object or bad callback'
  return [options, cb]

splitLongArray = (arr, max) ->
  throw new Error 'splitLongArray: bad params' unless arr instanceof Array and max > 0
  arr[(i*max)...((i+1)*max)] for i in [0...Math.ceil(arr.length/max)]

# This function soaks up num callbacks, by default returning the disjunction of Boolean results
# or returning on first error.... Reduce function causes different reduce behavior, such as concatenation
reduceCallbacks = (cb, num, reduce = ((a , b) -> (a or b)), init = false) ->
  return undefined unless cb?
  unless typeof cb is 'function' and num > 0 and typeof reduce is 'function'
    throw new Error 'Bad params given to reduceCallbacks'
  cbRetVal = init
  cbCount = 0
  cbErr = null
  return (err, res) ->
    unless cbErr
      if err
        cbErr = err
        cb err
      else
        cbCount++
        cbRetVal = reduce cbRetVal, res
        if cbCount is num
          cb null, cbRetVal
        else if cbCount > num
          throw new Error "reduceCallbacks callback invoked more than requested #{num} times"

concatReduce = (a, b) ->
  a = [a] unless a instanceof Array
  a.concat b

isInteger = (i) -> typeof i is 'number' and Math.floor(i) is i

# This smooths over the various different implementations...
_setImmediate = (func, args...) ->
  if Meteor?.setTimeout?
    return Meteor.setTimeout func, 0, args...
  else if setImmediate?
    return setImmediate func, args...
  else
    # Browser fallback
    return setTimeout func, 0, args...

_setInterval = (func, timeOut, args...) ->
  if Meteor?.setInterval?
    return Meteor.setInterval func, timeOut, args...
  else
    # Browser / node.js fallback
    return setInterval func, timeOut, args...

_clearInterval = (id) ->
  if Meteor?.clearInterval?
    return Meteor.clearInterval id
  else
    # Browser / node.js fallback
    return clearInterval id

###################################################################

class JobQueue

  constructor: (@root, @type, options..., @worker) ->
    unless @ instanceof JobQueue
      return new JobQueue @root, @type, options..., @worker
    [options, @worker] = optionsHelp options, @worker

    @pollInterval =
      if options.pollInterval? and not options.pollInterval
        Job.forever
      else if not (options.pollInterval? and isInteger(options.pollInterval))
        5000  # ms
      else
        options.pollInterval
    unless isInteger(@pollInterval) and @pollInterval >= 0
      throw new Error "JobQueue: Invalid pollInterval, must be a positive integer"

    @concurrency = options.concurrency ? 1
    unless isInteger(@concurrency) and @concurrency >= 0
      throw new Error "JobQueue: Invalid concurrency, must be a positive integer"

    @payload = options.payload ? 1
    unless isInteger(@payload) and @payload >= 0
      throw new Error "JobQueue: Invalid payload, must be a positive integer"

    @prefetch = options.prefetch ? 0
    unless isInteger(@prefetch) and @prefetch >= 0
      throw new Error "JobQueue: Invalid prefetch, must be a positive integer"

    @workTimeout = options.workTimeout  # No default
    if @workTimeout? and not (isInteger(@workTimeout) and @workTimeout >= 0)
      throw new Error "JobQueue: Invalid workTimeout, must be a positive integer"

    @_workers = {}
    @_tasks = []
    @_taskNumber = 0
    @_stoppingGetWork = undefined
    @_stoppingTasks = undefined
    @_interval = null
    @_getWorkOutstanding = false
    @paused = true
    @resume()

  _getWork: () ->
    unless @_getWorkOutstanding
      numJobsToGet = @prefetch + @payload*(@concurrency - @running()) - @length()
      if numJobsToGet > 0
        @_getWorkOutstanding = true
        options = { maxJobs: numJobsToGet }
        options.workTimeout = @workTimeout if @workTimeout?
        Job.getWork @root, @type, options, (err, jobs) =>
          @_getWorkOutstanding = false
          if err
            console.error "JobQueue: Received error from getWork(): ", err
          else if jobs? and jobs instanceof Array
            if jobs.length > numJobsToGet
              console.error "JobQueue: getWork() returned jobs (#{jobs.length}) in excess of maxJobs (#{numJobsToGet})"
            for j in jobs
              @_tasks.push j
              _setImmediate @_process.bind(@) unless @_stoppingGetWork?
            @_stoppingGetWork() if @_stoppingGetWork?
          else
            console.error "JobQueue: Nonarray response from server from getWork()"

  _only_once: (fn) ->
    called = false
    return () =>
      if called
        console.error "Callback called multiple times in JobQueue"
        throw new Error "Callback was already called."
      called = true
      fn.apply @, arguments

  _process: () ->
    if not @paused and @running() < @concurrency and @length()
      if @payload > 1
        job = @_tasks.splice 0, @payload
      else
        job = @_tasks.shift()
      job._taskId = "Task_#{@_taskNumber++}"
      @_workers[job._taskId] = job
      next = () =>
        delete @_workers[job._taskId]
        if @_stoppingTasks? and @running() is 0 and @length() is 0
          @_stoppingTasks()
        else
          _setImmediate @_process.bind(@)
          _setImmediate @_getWork.bind(@)
      cb = @_only_once next
      @worker job, cb

  _stopGetWork: (callback) ->
    _clearInterval @_interval
    if @_getWorkOutstanding
      @_stoppingGetWork = callback
    else
      _setImmediate callback  # No Zalgo, thanks

  _waitForTasks: (callback) ->
    unless @running() is 0
      @_stoppingTasks = callback
    else
      _setImmediate callback  # No Zalgo, thanks

  _failJobs: (tasks, callback) ->
    _setImmediate callback if tasks.length is 0  # No Zalgo, thanks
    count = 0
    for job in tasks
      job.fail "Worker shutdown", (err, res) =>
        count++
        if count is tasks.length
          callback()

  _hard: (callback) ->
    @paused = true
    @_stopGetWork () =>
      tasks = @_tasks
      @_tasks = []
      for i, r of @_workers
        tasks = tasks.concat r
      @_failJobs tasks, callback

  _stop: (callback) ->
    @paused = true
    @_stopGetWork () =>
      tasks = @_tasks
      @_tasks = []
      @_waitForTasks () =>
        @_failJobs tasks, callback

  _soft: (callback) ->
    @_stopGetWork () =>
      @_waitForTasks callback

  length: () -> @_tasks.length

  running: () -> Object.keys(@_workers).length

  idle: () -> @length() + @running() is 0

  full: () -> @running() is @concurrency

  pause: () ->
    return if @paused
    unless @pollInterval >= Job.forever
      _clearInterval @_interval
    @paused = true
    @

  resume: () ->
    return unless @paused
    @paused = false
    _setImmediate @_getWork.bind(@)
    unless @pollInterval >= Job.forever
      @_interval = _setInterval @_getWork.bind(@), @pollInterval
    for w in [1..@concurrency]
      _setImmediate @_process.bind(@)
    @

  trigger: () ->
    return if @paused
    _setImmediate @_getWork.bind(@)
    @

  shutdown: (options..., cb) ->
    [options, cb] = optionsHelp options, cb
    options.level ?= 'normal'
    options.quiet ?= false
    unless cb?
      console.warn "using default shutdown callback!" unless options.quiet
      cb = () =>
        console.warn "Shutdown complete"
    switch options.level
      when 'hard'
        console.warn "Shutting down hard" unless options.quiet
        @_hard cb
      when 'soft'
        console.warn "Shutting down soft" unless options.quiet
        @_soft cb
      else
        console.warn "Shutting down normally" unless options.quiet
        @_stop cb

###################################################################

class Job

  # This is the JS max int value = 2^53
  @forever = 9007199254740992

  # This is the maximum date value in JS
  @foreverDate = new Date 8640000000000000

  @jobPriorities:
    low: 10
    normal: 0
    medium: -5
    high: -10
    critical: -15

  @jobRetryBackoffMethods: [ 'constant', 'exponential' ]

  @jobStatuses: [ 'waiting', 'paused', 'ready', 'running'
                  'failed', 'cancelled', 'completed' ]

  @jobLogLevels: [ 'info', 'success', 'warning', 'danger' ]

  @jobStatusCancellable: [ 'running', 'ready', 'waiting', 'paused' ]
  @jobStatusPausable: [ 'ready', 'waiting' ]
  @jobStatusRemovable:   [ 'cancelled', 'completed', 'failed' ]
  @jobStatusRestartable: [ 'cancelled', 'failed' ]

  @ddpMethods = [ 'startJobs', 'stopJobs',  # Deprecated!
                  'startJobServer', 'shutdownJobServer',
                  'jobRemove', 'jobPause', 'jobResume', 'jobReady'
                  'jobCancel', 'jobRestart', 'jobSave', 'jobRerun', 'getWork'
                  'getJob', 'jobLog', 'jobProgress', 'jobDone', 'jobFail' ]

  @ddpPermissionLevels = [ 'admin', 'manager', 'creator', 'worker' ]

  # These are the four levels of the allow/deny permission heirarchy
  @ddpMethodPermissions =
    'startJobs': ['startJobs', 'admin']  # Deprecated!
    'stopJobs': ['stopJobs', 'admin']    # Deprecated!
    'startJobServer': ['startJobServer', 'admin']
    'shutdownJobServer': ['shutdownJobServer', 'admin']
    'jobRemove': ['jobRemove', 'admin', 'manager']
    'jobPause': ['jobPause', 'admin', 'manager']
    'jobResume': ['jobResume', 'admin', 'manager']
    'jobCancel': ['jobCancel', 'admin', 'manager']
    'jobReady': ['jobReady', 'admin', 'manager']
    'jobRestart': ['jobRestart', 'admin', 'manager']
    'jobSave': ['jobSave', 'admin', 'creator']
    'jobRerun': ['jobRerun', 'admin', 'creator']
    'getWork': ['getWork', 'admin', 'worker']
    'getJob': ['getJob', 'admin', 'worker']
    'jobLog': [ 'jobLog', 'admin', 'worker']
    'jobProgress': ['jobProgress', 'admin', 'worker']
    'jobDone': ['jobDone', 'admin', 'worker']
    'jobFail': ['jobFail', 'admin', 'worker']

  # Automatically work within Meteor, otherwise see @setDDP below
  @_ddp_apply: undefined

  # Class methods

  @_setDDPApply: (apply, collectionName) ->
    if typeof apply is 'function'
      if typeof collectionName is 'string'
         @_ddp_apply ?= {}
         if typeof @_ddp_apply is 'function'
            throw new Error "Job.setDDP must specify a collection name each time if called more than once."
         @_ddp_apply[collectionName] = apply
      else unless @_ddp_apply
         @_ddp_apply = apply
      else
         throw new Error "Job.setDDP must specify a collection name each time if called more than once."
    else
      throw new Error "Bad function in Job.setDDPApply()"

  # This needs to be called when not running in Meteor to use the local DDP connection.
  @setDDP: (ddp = null, collectionNames = null, Fiber = null) ->
    unless (typeof collectionNames is 'string') or (collectionNames instanceof Array)
      # Handle optional collection string with Fiber present
      Fiber = collectionNames
      collectionNames = [ undefined ]
    else if typeof collectionNames is 'string'
      # If string, convert to array of strings
      collectionNames = [ collectionNames ]
    for collName in collectionNames
      unless ddp? and ddp.close? and ddp.subscribe?
        # Not the DDP npm package
        if ddp is null and Meteor?.apply?
          # Meteor local server/client
          @_setDDPApply Meteor.apply, collName
        else
          # No other possibilities...
          throw new Error "Bad ddp object in Job.setDDP()"
      else unless ddp.observe?  # This is a Meteor DDP connection object
        @_setDDPApply ddp.apply.bind(ddp), collName
      else # This is the npm DDP package
        unless Fiber?
          @_setDDPApply ddp.call.bind(ddp), collName
        else
          # If Fibers in use under pure node.js,
          # make sure to yield and throw errors when no callback
          @_setDDPApply(((name, params, cb) ->
            fib = Fiber.current
            ddp.call name, params, (err, res) ->
              if cb? and typeof cb is 'function'
                cb err, res
              else
                if err
                  fib.throwInto err
                else
                  fib.run res
            if cb? and typeof cb is 'function'
              return
            else
              return Fiber.yield()
          ), collName)

  # Creates a job object by reserving the next available job of
  # the specified 'type' from the server queue root
  # returns null if no such job exists
  @getWork: (root, type, options..., cb) ->
    [options, cb] = optionsHelp options, cb
    type = [type] if typeof type is 'string'
    if options.workTimeout?
      unless isInteger(options.workTimeout) and options.workTimeout > 0
        throw new Error 'getWork: workTimeout must be a positive integer'
    methodCall root, "getWork", [type, options], cb, (res) =>
      jobs = (new Job(root, doc) for doc in res) or []
      if options.maxJobs?
        return jobs
      else
        return jobs[0]

  # This is defined above
  @processJobs: JobQueue

  # Makes a job object from a job document
  # This method is deprecated and will be removed
  @makeJob: do () ->
    depFlag = false
    (root, doc) ->
      unless depFlag
        depFlag = true
        console.warn "Job.makeJob(root, jobDoc) has been deprecated and will be removed in a future release, use 'new Job(root, jobDoc)' instead."
      new Job root, doc

  # Creates a job object by id from the server queue root
  # returns null if no such job exists
  @getJob: (root, id, options..., cb) ->
    [options, cb] = optionsHelp options, cb
    options.getLog ?= false
    methodCall root, "getJob", [id, options], cb, (doc) =>
      if doc
        new Job root, doc
      else
        undefined

  # Like the above, but takes an array of ids, returns array of jobs
  @getJobs: (root, ids, options..., cb) ->
    [options, cb] = optionsHelp options, cb
    options.getLog ?= false
    retVal = []
    chunksOfIds = splitLongArray ids, 32
    myCb = reduceCallbacks(cb, chunksOfIds.length, concatReduce, [])
    for chunkOfIds in chunksOfIds
      retVal = retVal.concat(methodCall root, "getJob", [chunkOfIds, options], myCb, (doc) =>
        if doc
          (new Job(root, d.type, d.data, d) for d in doc)
        else
          null)
    return retVal

  # Pause this job, only Ready and Waiting jobs can be paused
  # Calling this toggles the paused state. Unpaused jobs go to waiting
  @pauseJobs: (root, ids, options..., cb) ->
    [options, cb] = optionsHelp options, cb
    retVal = false
    chunksOfIds = splitLongArray ids, 256
    myCb = reduceCallbacks(cb, chunksOfIds.length)
    for chunkOfIds in chunksOfIds
      retVal ||= methodCall root, "jobPause", [chunkOfIds, options], myCb
    return retVal

  # Resume this job, only Paused jobs can be resumed
  # Calling this toggles the paused state. Unpaused jobs go to waiting
  @resumeJobs: (root, ids, options..., cb) ->
    [options, cb] = optionsHelp options, cb
    retVal = false
    chunksOfIds = splitLongArray ids, 256
    myCb = reduceCallbacks(cb, chunksOfIds.length)
    for chunkOfIds in chunksOfIds
      retVal ||= methodCall root, "jobResume", [chunkOfIds, options], myCb
    return retVal

  # Move waiting jobs to the ready state, jobs with dependencies will not
  # be made ready unless force is used.
  @readyJobs: (root, ids = [], options..., cb) ->
    [options, cb] = optionsHelp options, cb
    options.force ?= false
    retVal = false
    chunksOfIds = splitLongArray ids, 256
    chunksOfIds = [[]] unless chunksOfIds.length > 0
    myCb = reduceCallbacks(cb, chunksOfIds.length)
    for chunkOfIds in chunksOfIds
      retVal ||= methodCall root, "jobReady", [chunkOfIds, options], myCb
    return retVal

  # Cancel this job if it is running or able to run (waiting, ready)
  @cancelJobs: (root, ids, options..., cb) ->
    [options, cb] = optionsHelp options, cb
    options.antecedents ?= true
    retVal = false
    chunksOfIds = splitLongArray ids, 256
    myCb = reduceCallbacks(cb, chunksOfIds.length)
    for chunkOfIds in chunksOfIds
      retVal ||= methodCall root, "jobCancel", [chunkOfIds, options], myCb
    return retVal

  # Restart a failed or cancelled job
  @restartJobs: (root, ids, options..., cb) ->
    [options, cb] = optionsHelp options, cb
    options.retries ?= 1
    options.dependents ?= true
    retVal = false
    chunksOfIds = splitLongArray ids, 256
    myCb = reduceCallbacks(cb, chunksOfIds.length)
    for chunkOfIds in chunksOfIds
      retVal ||= methodCall root, "jobRestart", [chunkOfIds, options], myCb
    return retVal

  # Remove a job that is not able to run (completed, cancelled, failed) from the queue
  @removeJobs: (root, ids, options..., cb) ->
    [options, cb] = optionsHelp options, cb
    retVal = false
    chunksOfIds = splitLongArray ids, 256
    myCb = reduceCallbacks(cb, chunksOfIds.length)
    for chunkOfIds in chunksOfIds
      retVal ||= methodCall root, "jobRemove", [chunkOfIds, options], myCb
    return retVal

  # Start the job queue
  # Deprecated!
  @startJobs: (root, options..., cb) ->
    [options, cb] = optionsHelp options, cb
    methodCall root, "startJobs", [options], cb

  # Stop the job queue, stop all running jobs
  # Deprecated!
  @stopJobs: (root, options..., cb) ->
    [options, cb] = optionsHelp options, cb
    options.timeout ?= 60*1000
    methodCall root, "stopJobs", [options], cb

  # Start the job queue
  @startJobServer: (root, options..., cb) ->
    [options, cb] = optionsHelp options, cb
    methodCall root, "startJobServer", [options], cb

  # Shutdown the job queue, stop all running jobs
  @shutdownJobServer: (root, options..., cb) ->
    [options, cb] = optionsHelp options, cb
    options.timeout ?= 60*1000
    methodCall root, "shutdownJobServer", [options], cb

  # Job class instance constructor. When "new Job(...)" is run
  constructor: (@root, type, data) ->
    unless @ instanceof Job
      return new Job @root, type, data

    # Keep the original root, whatever type that is
    @_root = @root

    # Handle root as object with obj.root attribute
    if @root?.root? and typeof @root.root is 'string'
      @root = @_root.root

    # Handle (root, doc) signature
    if not data? and type?.data? and type?.type?
      if type instanceof Job
        return type

      doc = type
      data = doc.data
      type = doc.type
    else
      doc = {}

    unless typeof doc is 'object' and
           typeof data is 'object' and
           typeof type is 'string' and
           typeof @root is 'string'
      throw new Error "new Job: bad parameter(s), #{@root} (#{typeof @root}), #{type} (#{typeof type}), #{data} (#{typeof data}), #{doc} (#{typeof doc})"

    else if doc.type? and doc.data? # This case is used to create local Job objects from DDP calls
      @_doc = doc

    else  # This is the normal "create a new object" case
      time = new Date()
      @_doc =
        runId: null
        type : type
        data: data
        status: 'waiting'
        updated: time
        created: time
      @priority().retry().repeat().after().progress().depends().log("Constructed")

    return @

  # Override point for methods that have an echo option
  _echo: (message, level = null) ->
    switch level
      when 'danger' then console.error message
      when 'warning' then console.warn message
      when 'success' then console.log message
      else console.info message
    return

  # Adds a run dependancy on one or more existing jobs to this job
  # Calling with a falsy value resets the dependencies to []
  depends: (jobs) ->
    if jobs
      if jobs instanceof Job
        jobs = [ jobs ]
      if jobs instanceof Array
        depends = @_doc.depends
        for j in jobs
          unless j instanceof Job and j._doc._id?
            throw new Error 'Each provided object must be a saved Job instance (with an _id)'
          depends.push j._doc._id
      else
        throw new Error 'Bad input parameter: depends() accepts a falsy value, or Job or array of Jobs'
    else
      depends = []
    @_doc.depends = depends
    @_doc.resolved = []  # This is where prior depends go as they are satisfied
    return @

  # Set the run priority of this job
  priority: (level = 0) ->
    if typeof level is 'string'
      priority = Job.jobPriorities[level]
      unless priority?
        throw new Error 'Invalid string priority level provided'
    else if isInteger(level)
      priority = level
    else
      throw new Error 'priority must be an integer or valid priority level'
      priority = 0
    @_doc.priority = priority
    return @

  # Sets the number of attempted runs of this job and
  # the time to wait between successive attempts
  # Default, do not retry
  retry: (options = 0) ->
    if isInteger(options) and options >= 0
      options = { retries: options }
    if typeof options isnt 'object'
      throw new Error 'bad parameter: accepts either an integer >= 0 or an options object'
    if options.retries?
      unless isInteger(options.retries) and options.retries >= 0
        throw new Error 'bad option: retries must be an integer >= 0'
      options.retries++
    else
      options.retries = Job.forever
    if options.until?
      unless options.until instanceof Date
        throw new Error 'bad option: until must be a Date object'
    else
      options.until = Job.foreverDate
    if options.wait?
      unless isInteger(options.wait) and options.wait >= 0
        throw new Error 'bad option: wait must be an integer >= 0'
    else
      options.wait = 5*60*1000
    if options.backoff?
      unless options.backoff in Job.jobRetryBackoffMethods
        throw new Error 'bad option: invalid retry backoff method'
    else
      options.backoff = 'constant'

    @_doc.retries = options.retries
    @_doc.retryWait = options.wait
    @_doc.retried ?= 0
    @_doc.retryBackoff = options.backoff
    @_doc.retryUntil = options.until
    return @

  # Sets the number of times to repeatedly run this job
  # and the time to wait between successive runs
  # Default: repeat every 5 minutes, forever...
  repeat: (options = 0) ->
    if isInteger(options) and options >= 0
      options = { repeats: options }
    if typeof options isnt 'object'
      throw new Error 'bad parameter: accepts either an integer >= 0 or an options object'
    if options.wait? and options.schedule?
      throw new Error 'bad options: wait and schedule options are mutually exclusive'
    if options.repeats?
      unless isInteger(options.repeats) and options.repeats >= 0
        throw new Error 'bad option: repeats must be an integer >= 0'
    else
      options.repeats = Job.forever
    if options.until?
      unless options.until instanceof Date
        throw new Error 'bad option: until must be a Date object'
    else
      options.until = Job.foreverDate
    if options.wait?
      unless isInteger(options.wait) and options.wait >= 0
        throw new Error 'bad option: wait must be an integer >= 0'
    else
      options.wait = 5*60*1000
    if options.schedule?
      unless typeof options.schedule is 'object'
        throw new Error 'bad option, schedule option must be an object'
      unless options.schedule?.schedules? and options.schedule.schedules instanceof Array
        throw new Error 'bad option, schedule object requires a schedules attribute of type Array.'
      if options.schedule.exceptions? and not (options.schedule.exceptions instanceof Array)
        throw new Error 'bad option, schedule object exceptions attribute must be an Array'
      options.wait =
        schedules: options.schedule.schedules
        exceptions: options.schedule.exceptions

    @_doc.repeats = options.repeats
    @_doc.repeatWait = options.wait
    @_doc.repeated ?= 0
    @_doc.repeatUntil = options.until
    return @

  # Sets the delay before this job can run after it is saved
  delay: (wait = 0) ->
    unless isInteger(wait) and wait >= 0
      throw new Error 'Bad parameter, delay requires a non-negative integer.'
    return @after new Date(new Date().valueOf() + wait)

  # Sets a time after which this job can run once it is saved
  after: (time = new Date(0)) ->
    if typeof time is 'object' and time instanceof Date
      after = time
    else
      throw new Error 'Bad parameter, after requires a valid Date object'
    @_doc.after = after
    return @

  # Write a message to this job's log.
  log: (message, options..., cb) ->
    [options, cb] = optionsHelp options, cb
    options.level ?= 'info'
    unless typeof message is 'string'
      throw new Error 'Log message must be a string'
    unless typeof options.level is 'string' and options.level in Job.jobLogLevels
      throw new Error 'Log level options must be one of Job.jobLogLevels'
    if options.echo?
      if options.echo and Job.jobLogLevels.indexOf(options.level) >= Job.jobLogLevels.indexOf(options.echo)
        @_echo "LOG: #{options.level}, #{@_doc._id} #{@_doc.runId}: #{message}", options.level
      delete options.echo
    if @_doc._id?
      return methodCall @_root, "jobLog", [@_doc._id, @_doc.runId, message, options], cb
    else  # Log can be called on an unsaved job
      @_doc.log ?= []
      @_doc.log.push { time: new Date(), runId: null, level: options.level, message: message }
      if cb? and typeof cb is 'function'
        _setImmediate cb, null, true   # DO NOT release Zalgo
      return @  # Allow call chaining in this case

  # Indicate progress made for a running job. This is important for
  # long running jobs so the scheduler doesn't assume they are dead
  progress: (completed = 0, total = 1, options..., cb) ->
    [options, cb] = optionsHelp options, cb
    if (typeof completed is 'number' and
        typeof total is 'number' and
        completed >= 0 and
        total > 0 and
        total >= completed)
      progress =
        completed: completed
        total: total
        percent: 100*completed/total
      if options.echo
        delete options.echo
        @_echo "PROGRESS: #{@_doc._id} #{@_doc.runId}: #{progress.completed} out of #{progress.total} (#{progress.percent}%)"
      if @_doc._id? and @_doc.runId?
        return methodCall @_root, "jobProgress", [@_doc._id, @_doc.runId, completed, total, options], cb, (res) =>
          if res
            @_doc.progress = progress
          res
      else unless @_doc._id?
        @_doc.progress = progress
        if cb? and typeof cb is 'function'
          _setImmediate cb, null, true   # DO NOT release Zalgo
        return @
    else
      throw new Error "job.progress: something is wrong with progress params: #{@id}, #{completed} out of #{total}"
    return null

  # Save this job to the server job queue Collection it will also resave a modified job if the
  # job is not running and hasn't completed.
  save: (options..., cb) ->
    [options, cb] = optionsHelp options, cb
    return methodCall @_root, "jobSave", [@_doc, options], cb, (id) =>
      if id
        @_doc._id = id
      id

  # Refresh the local job state with the server job queue's version
  refresh: (options..., cb) ->
    [options, cb] = optionsHelp options, cb
    options.getLog ?= false
    if @_doc._id?
      return methodCall @_root, "getJob", [@_doc._id, options], cb, (doc) =>
        if doc?
          @_doc = doc
          @
        else
          false
    else
      throw new Error "Can't call .refresh() on an unsaved job"

  # Indicate to the server that this run has successfully finished.
  done: (result = {}, options..., cb) ->
    if typeof result is 'function'
      cb = result
      result = {}
    [options, cb] = optionsHelp options, cb
    unless result? and typeof result is 'object'
      result = { value: result }
    if @_doc._id? and @_doc.runId?
      return methodCall @_root, "jobDone", [@_doc._id, @_doc.runId, result, options], cb
    else
      throw new Error "Can't call .done() on an unsaved or non-running job"
    return null

  # Indicate to the server that this run has failed and provide an error message.
  fail: (result = "No error information provided", options..., cb) ->
    if typeof result is 'function'
      cb = result
      result = "No error information provided"
    [options, cb] = optionsHelp options, cb
    unless result? and typeof result is 'object'
      result = { value: result }
    options.fatal ?= false
    if @_doc._id? and @_doc.runId?
      return methodCall @_root, "jobFail", [@_doc._id, @_doc.runId, result, options], cb
    else
      throw new Error "Can't call .fail() on an unsaved or non-running job"
    return null

  # Pause this job, only Ready and Waiting jobs can be paused
  pause: (options..., cb) ->
    [options, cb] = optionsHelp options, cb
    if @_doc._id?
      return methodCall @_root, "jobPause", [@_doc._id, options], cb
    else
      @_doc.status = 'paused'
      if cb? and typeof cb is 'function'
        _setImmediate cb, null, true  # DO NOT release Zalgo
      return @
    return null

  # Resume this job, only Paused jobs can be resumed
  # Resumed jobs go to waiting
  resume: (options..., cb) ->
    [options, cb] = optionsHelp options, cb
    if @_doc._id?
      return methodCall @_root, "jobResume", [@_doc._id, options], cb
    else
      @_doc.status = 'waiting'
      if cb? and typeof cb is 'function'
        _setImmediate cb, null, true  # DO NOT release Zalgo
      return @
    return null

  # Make a waiting job ready to run. Jobs with dependencies only when forced
  ready: (options..., cb) ->
    [options, cb] = optionsHelp options, cb
    options.force ?= false
    if @_doc._id?
      return methodCall @_root, "jobReady", [@_doc._id, options], cb
    else
      throw new Error "Can't call .ready() on an unsaved job"
    return null

  # Cancel this job if it is running or able to run (waiting, ready)
  cancel: (options..., cb) ->
    [options, cb] = optionsHelp options, cb
    options.antecedents ?= true
    if @_doc._id?
      return methodCall @_root, "jobCancel", [@_doc._id, options], cb
    else
      throw new Error "Can't call .cancel() on an unsaved job"
    return null

  # Restart a failed or cancelled job
  restart: (options..., cb) ->
    [options, cb] = optionsHelp options, cb
    options.retries ?= 1
    options.dependents ?= true
    if @_doc._id?
      return methodCall @_root, "jobRestart", [@_doc._id, options], cb
    else
      throw new Error "Can't call .restart() on an unsaved job"
    return null

  # Run a completed job again as a new job, essentially a manual repeat
  rerun: (options..., cb) ->
    [options, cb] = optionsHelp options, cb
    options.repeats ?= 0
    options.wait ?= @_doc.repeatWait
    if @_doc._id?
      return methodCall @_root, "jobRerun", [@_doc._id, options], cb
    else
      throw new Error "Can't call .rerun() on an unsaved job"
    return null

  # Remove a job that is not able to run (completed, cancelled, failed) from the queue
  remove: (options..., cb) ->
    [options, cb] = optionsHelp options, cb
    if @_doc._id?
      return methodCall @_root, "jobRemove", [@_doc._id, options], cb
    else
      throw new Error "Can't call .remove() on an unsaved job"
    return null

    # Define convenience getters for some document properties
  Object.defineProperties @prototype,
    doc:
      get: () -> @_doc
      set: () -> console.warn "Job.doc cannot be directly assigned."
    type:
      get: () -> @_doc.type
      set: () -> console.warn "Job.type cannot be directly assigned."
    data:
      get: () -> @_doc.data
      set: () -> console.warn "Job.data cannot be directly assigned."

# Export Job in a npm package
if module?.exports?
  module.exports = Job
