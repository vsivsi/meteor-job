############################################################################
#     Copyright (C) 2014 by Vaughn Iverson
#     meteor-job-class is free software released under the MIT/X11 license.
#     See included LICENSE file for details.
############################################################################

# Exports Job object

methodCall = (root, method, params, cb, after = ((ret) -> ret)) ->
  # console.warn "Calling: #{root}_#{method} with: ", params
  name = "#{root}_#{method}"
  if cb and typeof cb is 'function'
    Job.ddp_apply name, params, (err, res) =>
      return cb err if err
      cb null, after(res)
  else
    return after(Job.ddp_apply name, params)

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
    @pollInterval = options.pollInterval ? 5000  # ms
    @concurrency = options.concurrency ? 1
    @payload = options.payload ? 1
    @prefetch = options.prefetch ? 0
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
    numJobsToGet = @prefetch + @payload*(@concurrency - @running()) - @length()
    console.log "Trying to get #{numJobsToGet} jobs via DDP"
    if numJobsToGet > 0
      @_getWorkOutstanding = true
      Job.getWork @root, @type, { maxJobs: numJobsToGet }, (err, jobs) =>
        if err
          console.error "Received error from getWork: ", err
        else if jobs?
          for j in jobs
            @_tasks.push j
            _setImmediate @_process.bind(@) unless @_stoppingGetWork?
          @_getWorkOutstanding = false
          @_stoppingGetWork() if @_stoppingGetWork?
        else
          console.log "No work from server"

  _only_once: (fn) ->
    called = false
    return () =>
      if called
        throw new Error("Callback was already called.")
      called = true
      fn.apply root, arguments

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
      cb = @_only_once next
      @worker job, cb

  _stopGetWork: (callback) ->
    _clearInterval @_interval
    if @_getWorkOutstanding
      @_stoppingGetWork = callback
    else
      callback()

  _waitForTasks: (callback) ->
    unless @running() is 0
      @_stoppingTasks = callback
    else
      callback()

  _failJobs: (tasks, callback) ->
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

  full: () -> @running is @concurrency

  pause: () ->
    return if @paused
    _clearInterval @_interval
    @paused = true

  resume: () ->
    return unless @paused
    @paused = false
    # @_getWork()
    @_interval = _setInterval @_getWork.bind(@), @pollInterval
    for w in [1..@concurrency]
      _setImmediate @_process.bind(@)()

  shutdown: (options..., cb) ->
    [options, cb] = optionsHelp options, cb
    options.level ?= 'normal'
    unless cb?
      cb = () =>
        console.warn "default shutdown complete callback!"
    switch options.level
      when 'hard'
        console.warn "Shutting down hard"
        @_hard cb
      when 'soft'
        console.warn "Shutting down soft"
        @_soft cb
      else
        console.warn "Shutting down normally"
        @_stop cb

###################################################################

class Job

  # This is the JS max int value = 2^53
  @forever = 9007199254740992

  @jobPriorities:
    low: 10
    normal: 0
    medium: -5
    high: -10
    critical: -15

  @jobStatuses: [
    'waiting'
    'paused'
    'ready'
    'running'
    'failed'
    'cancelled'
    'completed'
  ]

  @jobLogLevels: [
    'info'
    'success'
    'warning'
    'danger'
  ]

  @jobStatusCancellable: [ 'running', 'ready', 'waiting', 'paused' ]
  @jobStatusPausable: [ 'ready', 'waiting' ]
  @jobStatusRemovable:   [ 'cancelled', 'completed', 'failed' ]
  @jobStatusRestartable: [ 'cancelled', 'failed' ]

  # Automatically work within Meteor, otherwise see @setDDP below
  @ddp_apply: Meteor?.apply

  # Class methods

  # This needs to be called when not running in Meteor to use the local DDP connection.
  @setDDP: (ddp) ->
    if ddp? and ddp.call? and ddp.loginWithToken? # Since all functions have a call method...
      @ddp_apply = ddp.call.bind ddp
    else
      throw new Error "Bad ddp object in Job.setDDP()"

  # Creates a job object by reserving the next available job of
  # the specified 'type' from the server queue root
  # returns null if no such job exists
  @getWork: (root, type, options..., cb) ->
    [options, cb] = optionsHelp options, cb
    type = [type] if typeof type is 'string'
    methodCall root, "getWork", [type, options], cb, (res) =>
      jobs = (new Job(root, doc.type, doc.data, doc) for doc in res) or []
      if options.maxJobs?
        return jobs
      else
        return jobs[0]

  # This is defined above
  @processJobs: JobQueue

  # Creates a job object by id from the server queue root
  # returns null if no such job exists
  @makeJob: (root, doc) ->
    if root? and typeof root is 'string' and
        doc? and typeof doc is 'object' and doc.type? and
        typeof doc.type is 'string' and doc.data? and
        typeof doc.data is 'object' and doc._id?
      new Job root, doc.type, doc.data, doc
    else
      null

  # Creates a job object by id from the server queue root
  # returns null if no such job exists
  @getJob: (root, id, options..., cb) ->
    [options, cb] = optionsHelp options, cb
    options.getLog ?= false
    methodCall root, "getJob", [id, options], cb, (doc) =>
      if doc
        new Job root, doc.type, doc.data, doc
      else
        null

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

  # Pause this job, only Ready and Waiting jobs can be paused
  # Calling this toggles the paused state. Unpaused jobs go to waiting
  @resumeJobs: (root, ids, options..., cb) ->
    [options, cb] = optionsHelp options, cb
    retVal = false
    chunksOfIds = splitLongArray ids, 256
    myCb = reduceCallbacks(cb, chunksOfIds.length)
    for chunkOfIds in chunksOfIds
      retVal ||= methodCall root, "jobResume", [chunkOfIds, options], myCb
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
  @startJobs: (root, options..., cb) ->
    [options, cb] = optionsHelp options, cb
    methodCall root, "startJobs", [options], cb

  # Stop the job queue, stop all running jobs
  @stopJobs: (root, options..., cb) ->
    [options, cb] = optionsHelp options, cb
    options.timeout ?= 60*1000
    methodCall root, "stopJobs", [options], cb

  # Job class instance constructor. When "new Job(...)" is run
  constructor: (@root, type, data, doc = null) ->
    unless @ instanceof Job
      return new job @root, type, data
    @ddp_apply = Job.ddp_apply
    unless typeof doc is 'object' and
           typeof data is 'object' and
           typeof type is 'string' and
           typeof @root is 'string'
      console.error "new Job: bad parameter(s), #{@root} #{type}, #{data}, #{doc}"
      return null
    else if doc?  # This case is used to create local Job objects from DDP calls
      unless doc.type is type and doc.data is data
        console.error "rebuild Job: bad parameter(s), #{@root} #{type}, #{data}, #{doc}"
        return null
      @_doc = doc
      @type = type
      @data = data
    else  # This is the normal "create a new object" case
      @_doc =
        runId: null
        type : type
        data: data
        status: 'waiting'
        updated: new Date()
      @priority().retry({retries: 0}).repeat({repeats: 0}).after().progress().depends().log("Created")
      @type = @_doc.type
      @data = @_doc.data  # Make data a little easier to get to
      return @

  # Adds a run dependancy on one or more existing jobs to this job
  depends: (jobs) ->
    if jobs? and typeof jobs is 'object'
      if jobs instanceof Job and jobs._doc._id?
        depends = [ jobs._doc._id ]
      else if jobs instanceof Array
        depends = []
        for j in jobs when j instanceof Job and j._doc._id?
          depends.push j._doc._id
    else
      depends = []
    @_doc.depends = depends
    @_doc.resolved = []  # This is where prior depends go as they are satisfied
    return @

  # Set the run priority of this job
  priority: (level = 0) ->
    if typeof level is 'string'
      priority = Job.jobPriorities[level] ? 0
    else if typeof level is 'number'
      priority = level
    else
      priority = 0
    @_doc.priority = priority
    return @

  # Sets the number of attempted runs of this job and
  # the time to wait between successive attempts
  # Default, do not retry
  retry: (options) ->
    if typeof options isnt 'object'
      options = {}
    if typeof options.retries is 'number' and options.retries > 0
      options.retries++
    else
      options.retries = Job.forever

    unless typeof options.wait is 'number' and options.wait >= 0
      options.wait = 5*60*1000

    @_doc.retries = options.retries
    @_doc.retryWait = options.wait
    @_doc.retried ?= 0
    return @

  # Sets the number of times to repeatedly run this job
  # and the time to wait between successive runs
  # Default, run forever...
  repeat: (options) ->
    if typeof options isnt 'object'
      options = {}
    unless typeof options.repeats is 'number' and options.repeats >= 0
      options.repeats = Job.forever

    unless typeof options.wait is 'number' and options.wait >= 0
      options.wait = 5*60*1000

    @_doc.repeats = options.repeats
    @_doc.repeatWait = options.wait
    @_doc.repeated ?= 0
    return @

  # Sets the delay before this job can run after it is saved
  delay: (wait = 0) ->
    unless typeof wait is 'number' and wait >= 0
      wait = 0
    if typeof wait is 'number' and wait >= 0
      return @after new Date(new Date().valueOf() + wait)
    else
      return @after new Date()

  # Sets a time after which this job can run once it is saved
  after: (time) ->
    if typeof time is 'object' and time instanceof Date
      after = time
    else
      after = new Date()
    @_doc.after = after
    return @

  # Write a message to this job's log.
  log: (message, options..., cb) ->
    [options, cb] = optionsHelp options, cb
    options.level ?= 'info'
    if options.echo?
      delete options.echo
      out = "LOG: #{options.level}, #{@_doc._id} #{@_doc.runId}: #{message}"
      switch options.level
        when 'danger' then console.error out
        when 'warning' then console.warn out
        else console.log out
    if @_doc._id?
      return methodCall @root, "jobLog", [@_doc._id, @_doc.runId, message, options], cb
    else  # Log can be called on an unsaved job
      @_doc.log ?= []
      @_doc.log.push { time: new Date(), runId: null, level: 'success', message: message }
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
      if options.echo?
        delete options.echo
        console.log "PROGRESS: #{@_doc._id} #{@_doc.runId}: #{progress.completed} out of #{progress.total} (#{progress.percent}%)"
      if @_doc._id? and @_doc.runId?
        return methodCall @root, "jobProgress", [@_doc._id, @_doc.runId, completed, total, options], cb, (res) =>
          if res
            @_doc.progress = progress
          res
      else unless @_doc._id?
        @_doc.progress = progress
        if cb? and typeof cb is 'function'
          _setImmediate cb, null, true   # DO NOT release Zalgo
        return @
    else
      console.warn "job.progress: something's wrong with progress: #{@id}, #{completed} out of #{total}"
    return null

  # Save this job to the server job queue Collection it will also resave a modified job if the
  # job is not running and hasn't completed.
  save: (options..., cb) ->
    [options, cb] = optionsHelp options, cb
    console.log "About to submit a job", @_doc
    return methodCall @root, "jobSave", [@_doc, options], cb, (id) =>
      if id
        @_doc._id = id
      id

  # Refresh the local job state with the server job queue's version
  refresh: (options..., cb) ->
    [options, cb] = optionsHelp options, cb
    options.getLog ?= false
    if @_doc._id?
      return methodCall @root, "getJob", [@_doc._id, options], cb, (doc) =>
        if doc?
          @_doc = doc
          @type = @_doc.type
          @data = @_doc.data
          true
        else
          false
    else
      console.warn "Can't refresh an unsaved job"
      if cb? and typeof cb is 'function'
        _setImmediate cb, null, null   # DO NOT release Zalgo
      return false

  # Indicate to the server than this run has successfully finished.
  done: (result = {}, options..., cb) ->
    [options, cb] = optionsHelp options, cb
    if @_doc._id? and @_doc.runId?
      return methodCall @root, "jobDone", [@_doc._id, @_doc.runId, result, options], cb
    else
      console.warn "Can't finish an unsaved job"
      if cb? and typeof cb is 'function'
        _setImmediate cb, null, null   # DO NOT release Zalgo
    return null

  # Indicate to the server than this run has failed and provide an error message.
  fail: (err, options..., cb) ->
    [options, cb] = optionsHelp options, cb
    options.fatal ?= false
    if @_doc._id? and @_doc.runId?
      return methodCall @root, "jobFail", [@_doc._id, @_doc.runId, err, options], cb
    else
      console.warn "Can't fail an unsaved job"
      if cb? and typeof cb is 'function'
        _setImmediate cb, null, null   # DO NOT release Zalgo
    return null

  # Pause this job, only Ready and Waiting jobs can be paused
  pause: (options..., cb) ->
    [options, cb] = optionsHelp options, cb
    if @_doc._id?
      return methodCall @root, "jobPause", [@_doc._id, options], cb
    else
      if @_doc.status is 'waiting'
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
      return methodCall @root, "jobResume", [@_doc._id, options], cb
    else
      if @_doc.status is 'paused'
        @_doc.status = 'waiting'
        if cb? and typeof cb is 'function'
          _setImmediate cb, null, true  # DO NOT release Zalgo
        return @
    return null

  # Cancel this job if it is running or able to run (waiting, ready)
  cancel: (options..., cb) ->
    [options, cb] = optionsHelp options, cb
    options.antecedents ?= true
    if @_doc._id?
      return methodCall @root, "jobCancel", [@_doc._id, options], cb
    else
      if cb? and typeof cb is 'function'
        _setImmediate cb, null, false  # DO NOT release Zalgo
      console.warn "Can't cancel an unsaved job"
    return null

  # Restart a failed or cancelled job
  restart: (options..., cb) ->
    [options, cb] = optionsHelp options, cb
    options.retries ?= 1
    options.dependents ?= true
    if @_doc._id?
      return methodCall @root, "jobRestart", [@_doc._id, options], cb
    else
      console.warn "Can't restart an unsaved job"
      if cb? and typeof cb is 'function'
        _setImmediate cb, null, null   # DO NOT release Zalgo
    return null

  # Run a completed job again as a new job, essentially a manual repeat
  rerun: (options..., cb) ->
    [options, cb] = optionsHelp options, cb
    options.repeats ?= 0
    options.wait ?= @_doc.repeatWait
    if @_doc._id?
      return methodCall @root, "jobRerun", [@_doc._id, options], cb
    else
      console.warn "Can't rerun an unsaved job"
      if cb? and typeof cb is 'function'
        _setImmediate cb, null, null   # DO NOT release Zalgo
    return null

  # Remove a job that is not able to run (completed, cancelled, failed) from the queue
  remove: (options..., cb) ->
    [options, cb] = optionsHelp options, cb
    if @_doc._id?
      return methodCall @root, "jobRemove", [@_doc._id, options], cb
    else
      console.warn "Can't remove an unsaved job"
      if cb? and typeof cb is 'function'
        _setImmediate cb, null, null   # DO NOT release Zalgo
    return null

# Export Job in a npm package
if module?.exports?
  module.exports = Job
