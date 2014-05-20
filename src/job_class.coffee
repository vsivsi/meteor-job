############################################################################
#     Copyright (C) 2014 by Vaughn Iverson
#     meteor-job-class is free software released under the MIT/X11 license.
#     See included LICENSE file for details.
############################################################################

# Exports Job object

# retHelp = (err, ret, cb) ->
#   if cb and typeof cb is 'function'
#     return cb err, ret
#   else unless err
#     return ret
#   else
#     throw err

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
  if cb? and typeof cb isnt 'function'
    options = cb
    cb = undefined
  else
    options = options?[0] ? {}
  if typeof options isnt 'object'
    console.error "Bad options object", options
    options = {}
  return [options, cb]

splitLongArray = (arr, max) ->
  arr[(i*max)...((i+1)*max)] for i in [0...arr.length] by max

callbackGenerator = (cb, num) ->
  return undefined unless cb?
  cbRetVal = false
  cbCount = 0
  cbErr = null
  return (err, res) ->
    unless cbErr
      if err
        cbErr = err
        cb err
      else
        cbCount++
        cbRetVal ||= res
        if cbCount is num
          cb null, cbRetVal

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
    'default'
    'success'
    'info'
    'warning'
    'danger'
  ]

  @jobStatusCancellable: [ 'running', 'ready', 'waiting', 'paused' ]
  @jobStatusPausable: [ 'ready', 'waiting', 'paused' ]
  @jobStatusRemovable:   [ 'cancelled', 'completed', 'failed' ]
  @jobStatusRestartable: [ 'cancelled', 'failed' ]

  # Automatically work within Meteor, otherwise see @setDDP below
  @ddp_apply: Meteor?.apply

  # Class methods

  # This needs to be called when not running in Meteor to use the local DDP connection.
  @setDDP: (ddp) ->
    if ddp? and ddp.call?
      @ddp_apply = ddp.call.bind ddp
    else
      console.error "Bad ddp object in Job.setDDP()"

  # Start the job queue
  @startJobs: (root, options..., cb) ->
    [options, cb] = optionsHelp options, cb
    methodCall root, "startJobs", [options], cb

  # Stop the job queue, stop all running jobs
  @stopJobs: (root, options..., cb) ->
    [options, cb] = optionsHelp options, cb
    options.timeout ?= 60*1000
    methodCall root, "stopJobs", [options], cb

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
    methodCall root, "getJob", [ids, options], cb, (doc) =>
      if doc
        (new Job(root, d.type, d.data, d) for d in doc)
      else
        null

  # Pause this job, only Ready and Waiting jobs can be paused
  # Calling this toggles the paused state. Unpaused jobs go to waiting
  @pauseJobs: (root, ids, options..., cb) ->
    [options, cb] = optionsHelp options, cb
    return methodCall root, "jobPause", [ids, options], cb

  # Cancel this job if it is running or able to run (waiting, ready)
  @cancelJobs: (root, ids, options..., cb) ->
    [options, cb] = optionsHelp options, cb
    options.antecedents ?= true
    retVal = false
    chunksOfIds = splitLongArray ids, max
    for chunkOfIds in chunksOfIds
      retVal ||= methodCall root, "jobCancel", [chunkOfIds, options], callbackGenerator(cb, max)
    return retVal

  # Restart a failed or cancelled job
  @restartJobs: (root, ids, options..., cb) ->
    [options, cb] = optionsHelp options, cb
    options.retries ?= 1
    options.dependents ?= true
    return methodCall root, "jobRestart", [ids, options], cb

  # Remove a job that is not able to run (completed, cancelled, failed) from the queue
  @removeJobs: (root, ids, options..., cb) ->
    [options, cb] = optionsHelp options, cb
    return methodCall root, "jobRemove", [ids, options], cb

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
      console.error "Bad options object", options
      options = {}
    if typeof options.retries is 'number' and options.retries > 0
      options.retries++
    else
      options.retries = Job.forever

    unless typeof options.retryWait is 'number' and options.retryWait >= 0
      options.retryWait = 5*60*1000

    @_doc.retries = options.retries
    @_doc.retryWait = options.retryWait
    @_doc.retried ?= 0
    return @

  # Sets the number of times to repeatedly run this job
  # and the time to wait between successive runs
  # Default, run forever...
  repeat: (options) ->
    if typeof options isnt 'object'
      console.error "Bad options object", options
      options = {}
    unless typeof options.repeats is 'number' and options.repeats >= 0
      options.repeats = Job.forever

    unless typeof options.repeatWait is 'number' and options.repeatWait >= 0
      options.repeatWait = 5*60*1000

    @_doc.repeats = options.repeats
    @_doc.repeatWait = options.repeatWait
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
    options.level ?= 'default'
    if options.echo?
      delete options.echo
      out = "LOG: #{options.level}, #{@_doc._id} #{@_doc.runId} #{message}"
      switch options.level
        when 'danger' then console.error out
        when 'warning' then console.warn out
        else console.log out
    if @_doc._id?
      return methodCall @root, "jobLog", [@_doc._id, @_doc.runId, message, options], cb
    else  # Log can be called on an unsaved job
      @_doc.log ?= []
      @_doc.log.push { time: new Date(), runId: null, level: 'success', message: message }
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
      if @_doc._id? and @_doc.runId?
        return methodCall @root, "jobProgress", [@_doc._id, @_doc.runId, completed, total, options], cb, (res) =>
          if res
            @_doc.progress = progress
          res
      else
        @_doc.progress = progress
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
          true
        else
          false
    else
      console.warn "Can't refresh an unsaved job"
      return false

  # Indicate to the server than this run has successfully finished.
  done: (options..., cb) ->
    [options, cb] = optionsHelp options, cb
    if @_doc._id? and @_doc.runId?
      return methodCall @root, "jobDone", [@_doc._id, @_doc.runId, options], cb
    else
      console.warn "Can't finish an unsaved job"
    return null

  # Indicate to the server than this run has failed and provide an error message.
  fail: (err, options..., cb) ->
    [options, cb] = optionsHelp options, cb
    options.fatal ?= false
    if @_doc._id? and @_doc.runId?
      return methodCall @root, "jobFail", [@_doc._id, @_doc.runId, err, options], cb
    else
      console.warn "Can't fail an unsaved job"
    return null

  # Pause this job, only Ready and Waiting jobs can be paused
  # Calling this toggles the paused state. Unpaused jobs go to waiting
  pause: (options..., cb) ->
    [options, cb] = optionsHelp options, cb
    if @_doc._id?
      return methodCall @root, "jobPause", [@_doc._id, options], cb
    else
      console.warn "Can't pause an unsaved job"
    return null

  # Cancel this job if it is running or able to run (waiting, ready)
  cancel: (options..., cb) ->
    [options, cb] = optionsHelp options, cb
    options.antecedents ?= true
    if @_doc._id?
      return methodCall @root, "jobCancel", [@_doc._id, options], cb
    else
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
    return null

  # Remove a job that is not able to run (completed, cancelled, failed) from the queue
  remove: (options..., cb) ->
    [options, cb] = optionsHelp options, cb
    if @_doc._id?
      return methodCall @root, "jobRemove", [@_doc._id, options], cb
    else
      console.warn "Can't remove an unsaved job"
    return null

# Export Job in a npm package
if module?.exports?
  module.exports = Job
