############################################################################
#     Copyright (C) 2014 by Vaughn Iverson
#     meteor-job-class is free software released under the MIT/X11 license.
#     See included LICENSE file for details.
############################################################################

# Exports Job object

# This is the JS max int value = 2^53

retHelp = (err, ret, cb) ->
  if cb and typeof cb is 'function'
    return cb err, ret
  else unless err
    return ret
  else
    throw err

methodCall = (root, method, params, cb, after = ((ret) -> ret)) ->
  console.warn "Calling: #{method}_#{root} with: ", params
  name = "#{method}_#{root}"
  if cb and typeof cb is 'function'
    Job.ddp_apply name, params, (err, res) =>
      return cb err if err
      cb null, after(res)
  else
    return after(Job.ddp_apply name, params)

class Job

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
    options = options?[0] ? {}
    if typeof options isnt 'object'
      return retHelp new Error("Bad options parameter"), null, cb
    methodCall root, "startJobs", [options], cb

  # Stop the job queue, stop all running jobs
  @stopJobs: (root, options..., cb) ->
    options = params?[0] ? {}
    if typeof options isnt 'object'
      return retHelp new Error("Bad options parameter"), null, cb
    options.timeout ?= 60*1000
    methodCall root, "stopJobs", [options], cb

  # Creates a job object by id from the server queue root
  # returns null if no such job exists
  @getJob: (root, id, options..., cb) ->
    options = options?[0] ? {}
    if typeof options isnt 'object'
      return retHelp new Error("Bad options parameter"), null, cb
    methodCall root, "getJob", [id, options], cb, (doc) =>
      if doc
        new Job root, doc.type, doc.data, doc
      else
        null

  # Creates a job object by reserving the next available job of
  # the specified 'type' from the server queue root
  # returns null if no such job exists
  @getWork: (root, type, options..., cb) ->
    options = options?[0] ? {}
    if typeof options isnt 'object'
      return retHelp new Error("Bad options parameter"), null, cb
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
      @.data = data
    else  # This is the normal "create a new object" case
      @_doc =
        runId: null
        type : type
        data: data
        status: 'waiting'
        updated: new Date()
      @priority().retry({retries: 0}).repeat({repeats: 0}).after().progress().depends().log("Created")
      @.data = @_doc.data  # Make data a little easier to get to
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
    options = options ? {}
    if typeof options isnt 'object'
      return retHelp new Error("Bad options parameter"), null, cb

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
    options = options ? {}
    if typeof options isnt 'object'
      return retHelp new Error("Bad options parameter"), null, cb

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
  log: (message, cb) ->
    if @_doc._id?
      if cb and typeof cb is 'function'
        @ddp_apply "jobLog_#{@root}", [@_doc._id, @_doc.runId, message], (err, res) =>
          return cb err if err
          return cb null, res
      else
        res = @ddp_apply "jobLog_#{@root}", [@_doc._id, @_doc.runId, message]
        return res
    else
      @_doc.log ?= []
      @_doc.log.push { time: new Date(), runId: null, message: message }
      return @

  # Indicate progress made for a running job. This is important for
  # long running jobs so the scheduler doesn't assume they are dead
  progress: (completed = 0, total = 1, cb) ->
    if (typeof completed is 'number' and
        typeof total is 'number' and
        completed >= 0 and
        total > 0 and
        total >= completed)
      progress = { completed: completed, total: total, percent: 100*completed/total }
      if @_doc._id? and @_doc.runId?
        if cb and typeof cb is 'function'
          @ddp_apply "jobProgress_#{@root}", [@_doc._id, @_doc.runId, progress], (err, res) =>
            return cb err if err
            @_doc.progress = progress
            return cb null, res
        else
          res = @ddp_apply "jobProgress_#{@root}", [@_doc._id, @_doc.runId, progress]
          @_doc.progress = progress
          return res
      else
        @_doc.progress = progress
        return @
    else
      console.warn "job.progress: something's wrong with progress: #{@id}, #{completed} out of #{total}"
    return null

  # Save this job to the server job queue Collection it will also resave a modified job if the
  # job is not running and hasn't completed.
  save: (cb) ->
    console.log "About to submit a job", @_doc
    if cb and typeof cb is 'function'
      @ddp_apply "jobSubmit_#{@root}", [@_doc], (err, id) =>
        return cb err if err
        @_doc._id = id
        return cb null, id
      return true
    else
      id = @ddp_apply "jobSubmit_#{@root}", [@_doc]
      @_doc._id = id
      return id

  # Refresh the local job state with the server job queue's version
  refresh: (cb) ->
    if @_doc._id?
      if cb and typeof cb is 'function'
        @ddp_apply "getJob_#{@root}", [@_doc._id], (err, doc) =>
          return cb err if err
          return cb new Error "Refresh failed, doc not found" unless doc?
          @_doc = doc
          return cb null, true
      else
        doc = @ddp_apply "getJob_#{@root}", [@_doc._id]
        if doc?
          @_doc = doc
          return true
        else
          return false
    else
      console.warn "Can't refresh an unsaved job"
      return false

  # Fetches a job's current log array by id from the server
  # queue root returns null if no such job exists
  getLog: (cb) ->
    if cb and typeof cb is 'function'
      @ddp_apply "getLog_#{@root}", [@_doc.id], (err, doc) =>
        return cb err if err
        return cb new Error "Refresh failed, doc not found"
        unless doc?
          return cb null, doc.log
        else
          return cb null, null
    else
      doc = @ddp_apply "getLog_#{@root}", [@_doc.id]
      if doc
        return doc.log
      else
        return null

  # Indicate to the server than this run has successfully finished.
  done: (cb) ->
    if @_doc._id? and @_doc.runId?
      if cb and typeof cb is 'function'
        @ddp_apply "jobDone_#{@root}", [@_doc._id, @_doc.runId], (err, res) =>
        return cb err if err
        return cb null, res
      else
        res = @ddp_apply "jobDone_#{@root}", [@_doc._id, @_doc.runId]
        return res
    else
      console.warn "Can't finish an unsaved job"
    return null

  # Indicate to the server than this run has failed and provide an error message.
  fail: (err, cb) ->
    if @_doc._id? and @_doc.runId?
      if cb and typeof cb is 'function'
        @ddp_apply "jobFail_#{@root}", [@_doc._id, @_doc.runId, err], (err, res) =>
        return cb err if err
        return cb null, res
      else
        res = @ddp_apply "jobFail_#{@root}", [@_doc._id, @_doc.runId, err]
        return res
    else
      console.warn "Can't fail an unsaved job"
    return null

  # Pause this job, only Ready and Waiting jobs can be paused
  # Calling this toggles the paused state. Unpaused jobs go to waiting
  pause: (cb) ->
    if @_doc._id?
      if cb and typeof cb is 'function'
        @ddp_apply "jobPause_#{@root}", [@_doc._id], (err, res) =>
        return cb err if err
        return cb null, res
      else
        res = @ddp_apply "jobPause_#{@root}", [@_doc._id]
        return res
    else
      console.warn "Can't pause an unsaved job"
    return null

  # Cancel this job if it is running or able to run (waiting, ready)
  cancel: (params..., cb) ->
    antecedents = params?[0] ? false
    if @_doc._id?
      if cb and typeof cb is 'function'
        @ddp_apply "jobCancel_#{@root}", [@_doc._id, antecedents], (err, res) =>
        return cb err if err
        return cb null, res
      else
        res = @ddp_apply "jobCancel_#{@root}", [@_doc._id, antecedents]
        return res
    else
      console.warn "Can't cancel an unsaved job"
    return null

  # Restart a failed or cancelled job
  restart: (params..., cb) ->
    retries = params?[0] ? 1
    dependents = params?[1] ? false
    if @_doc._id?
      if cb and typeof cb is 'function'
        @ddp_apply "jobRestart_#{@root}", [@_doc._id, retries, dependents], (err, res) =>
        return cb err if err
        return cb null, res
      else
        res = @ddp_apply "jobRestart_#{@root}", [@_doc._id, retries, dependents]
        return res
    else
      console.warn "Can't restart an unsaved job"
    return null

  # Remove a job that is not able to run (completed, cancelled, failed) from the queue
  remove: (cb) ->
    if @_doc._id?
      if cb and typeof cb is 'function'
        @ddp_apply "jobRemove_#{@root}", [@_doc._id], (err, res) =>
        return cb err if err
        return cb null, res
      else
        res = @ddp_apply "jobRemove_#{@root}", [@_doc._id]
        return res
    else
      console.warn "Can't remove an unsaved job"
    return null

# Export Job in a npm package
if module?.exports?
  module.exports = Job
