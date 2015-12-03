meteor-job
======================================

[![Build Status](https://travis-ci.org/vsivsi/meteor-job.svg)](https://travis-ci.org/vsivsi/meteor-job)

## Intro

Meteor Job is a pure Javascript implementation of the `Job` and `JobQueue` classes that form the foundation of the [`job-collection` Atmosphere package](https://atmospherejs.com/vsivsi/job-collection) for Meteor. This package is used internally by `job-collection` on Meteor, but you should also use it for any job workers you would like to run outside of the Meteor environment as ordinary node.js programs.

Here's a very basic example that ignores authentication and connection error handling:

```javascript
var DDP = require('ddp');
var Job = require('meteor-job')

// In this case a local Meteor instance, could be anywhere...
var ddp = new DDP({
  host: "127.0.0.1",
  port: 3000,
  use_ejson: true
});

// Job uses DDP Method calls to communicate with the Meteor jobCollection.
// Within Meteor, it can make those calls directly, but outside of Meteor
// you need to hook it up with a working DDP connection it can use.
Job.setDDP(ddp);

// Once we have a valid connection, we're in business
ddp.connect(function (err) {
  if (err) throw err;

  // Worker function for jobs of type 'somejob'
  var somejobWorker = function (job, cb) {
    job.log("Some message");
    // Work on job...
    job.progress(50, 100);  // Half done!
    // Work some more...
    var jobError = (Math.random() > 0.9); // Could fail!
    if (jobError) {
      job.fail("Some error happened...");
    } else {
      job.done();
    }
    cb(null); // Don't forget!
  };

  // Get jobs of type 'somejob' available in the
  // 'jobPile' jobCollection for somejobWorker
  var workers = Job.processJobs('jobPile', 'somejob', somejobWorker);
});
```

## Installation

`npm install meteor-job`

Unit tests may be run from within the node_modules/meteor-job directory by:
```bash
npm test
# or
make test
```

## Usage

### Getting connected

First you need to establish a [DDP connection](https://github.com/oortcloud/node-ddp-client) with the Meteor server hosting the jobCollection you wish to work on. You will probably need to authenticate as well unless the Meteor server is wide open for unauthenticated DDP Method calls, which it really shouldn't be. I have written another npm package [ddp-login](https://www.npmjs.org/package/ddp-login) which makes secure authentication with Meteor from node.js a snap.

```javascript
var DDP = require('ddp');
var DDPlogin = require('ddp-login');
var Job = require('meteor-job')

// See DDP package docs for options here...
var ddp = new DDP({
  host: "127.0.0.1",
  port: 3000,
  use_ejson: true
});

Job.setDDP(ddp);

ddp.connect(function (err) {
  if (err) throw err;

  // The call below will look for an existing authentication token in
  // process.env.METEOR_TOKEN. If it find one and it is still valid,
  // authentication will be transparent. If not, the user will be prompted
  // for the e-mail and password to an account on the connected Meteor
  // server. This is the default case... ddp-login has other options
  // documented at https://www.npmjs.org/package/ddp-login
  DDPlogin(ddp, function (err, token) {
    if (err) throw err;

    // From here we can get to work, as long as the DDP connection is good.
    // See the DDP package for details on DDP auto_reconnect, and handling
    // socket events.

    // Do stuff!!!

  });
}
```

### Job workers

Okay, so you've got an authenticated DDP connection, and you'd like to get to work, now what?

```javascript
// 'jobQueue' is the name of the jobCollection on the server
// 'jobType' is the name of the kind of job you'd like to work on
Job.getWork('jobQueue', 'jobType', function (err, job) {
  if (job) {
     // You got a job!!!  Better work on it!
     // At this point the jobCollection has changed the job status to
     // 'running' so you are now responsible to eventually call either
     // job.done() or job.fail()
  }
});
```

However, `Job.getWork()` is kind of low-level. It only makes one request for a job. What you probably really want is to get some work whenever it becomes available and you aren't too busy:

```javascript
var workers = Job.processJobs('jobQueue', 'jobType', { concurrency: 4 },
  function (job, cb) {
    // This will only be called if a job is obtained from Job.getWork()
    // Up to four of these worker functions can be outstanding at
    // a time based on the concurrency option...

    // Be sure to invoke the callback when this job has been
    // completed or failed.
    cb();

  }
);
```

Once you have a job, you can work on it, log messages, indicate progress and either succeed or fail.

```javascript
// This code assumed to be running in a Job.processJobs() callback
var count = 0;

// In this example, assume that each job may contain
// multiple emails to be sent within the job's data.
var total = job.data.emailsToSend.length;
var retryLater = [];

// Most job methods have optional callbacks if you really want to be sure...
job.log("Attempting to send " + total + " emails",
  function(err, result) {
    // err would be a DDP or server error
    // If no error, the result will indicate what happened in jobCollection
  }
);

job.progress(count, total);

if (networkDown()) {
  // You can add a string message to a failing job
  job.fail("Network is down!!!");
  cb();
} else {
  job.data.emailsToSend.forEach(function (email) {
    sendEmail(email.address, email.subject, email.message,
      function(err) {
        count++;
        job.progress(count, total);
        if (err) {
          job.log("Sending to " + email.address + "failed",
                  {level: 'warning'});
          retryLater.push(email);
        }
        if (count === total) {
          // You can attach a result object to a successful job
          job.done({ retry: retryLater });
          cb();
        }
      }
    );
  });
}
```

The error handling mechanism in the above code seems pretty clunky... How do those failed messages get retried?
This approach probably will probably be easier to manage:

```javascript
var workers = Job.processJobs('jobQueue', 'jobType', { payload: 20 },
  function (jobs, cb) {
    // jobs is an array of jobs, between 1 and 20 long,
    // triggered by the option payload being > 1
    var count = 0;

    jobs.forEach(function (job) {
      var email = job.data.email // Only one email per job
      sendEmail(email.address, email.subject, email.message, function(err) {
        count++;
        if (err) {
          job.log("Sending failed with error" + err, {level: 'warning'});
          job.fail("" + err);
        } else {
          job.done();
        }
        if (count === jobs.length) {
          cb();  // Tells the processJobs we're done
        }
      });
    });
  }
);
```

With the above logic, each email can succeed or fail individually, and retrying later can be directly handled by the jobCollection itself.

The jobQueue object returned by `Job.processJobs()` has methods that can be used to determine its status and control its behavior. See the jobQueue API reference for more detail.

### Job creators

If you'd like to create an entirely new job and submit it to a jobCollection, here's how:

```javascript
var job = new Job('jobQueue', 'jobType', { work: "to", be: "done" });

// Set some options on the new job before submitting it. These option setting
// methods do not take callbacks because they only affect the local job object.
// See also: job.repeat(), job.after(), job.depends()

job.priority('normal')     // These methods return job and so are chainable.
   .retry({retries: 5,         // Retry up to five times
           wait: 15*60*1000})  //waiting 15 minutes per attempt
   .delay(15000);          // Don't run until 15 seconds have passed

// Save the job to be added to the Meteor jobCollection via DDP
job.save(function (err, result) {
  if (!err && result) {
    console.log("New job saved with Id: " + result);
  }
});
```

**Note:** It's likely that you'll want to think carefully about whether node.js programs should be allowed to create and manage jobs. Meteor jobCollection provides an extremely flexible mechanism to allow or deny specific actions that are attempted outside of trusted server code. As such, the code above (specifically the `job.save()`) may be rejected by the Meteor server depending on how it is configured. The same caveat applies to all of the job management methods described below.

### Job managers

Management of the jobCollection itself is accomplished using a mixture of Job class methods and methods on individual job objects:

```javascript
// Get a job object by Id
Job.getJob('jobQueue', id, function (err, job) {
  // Note, this is NOT the same a Job.getWork()
  // This call returns a job object, but does not change
  // the status to 'running'.
  // So you can't work on this job.
});

// If your job object's information gets stale, you can refresh it
job.refresh(function (err, result) {
  // job is refreshed
});

// Make a job object from a job document (which you
// can obtain by subscribing to a jobCollection)
job = new Job('jobQueue', jobDoc);  // No callback!

// Note that jobCollections are reactive, just like any
// other Meteor collection. So if you are subscribed,
// the job documents in the collection will auto-update.
// Then you can use new Job() to turn a job doc into a
// job object whenever necessary without another DDP round trip

// Once you have a job object you can change many of its
// settings (but only while it's paused)
job.pause(function (err, result) {   // Prohibit the job from running
  job.priority('low');   // Change its priority
  job.save();            // Update its priority in the jobCollection
                         // This also automatically triggers a job.resume()
                         // which is how you'd otherwise get it running again.
});

// You can also cancel jobs that are running or are waiting to run.
job.cancel();

// You can restart a cancelled or failed job
job.restart();

// Or re-run a job that has already completed successfully
job.rerun();

// And you can remove a job, so long as it's cancelled,
// completed or failed. If it's running or in any other state,
// you'll need to cancel it before you can remove it.
job.remove();

// For bulk operations on acting on more than one job at a time,
// there are also Class methods that take arrays of job Ids.
// For example, cancelling a whole batch of jobs at once:
Job.cancelJobs('jobQueue', Ids, function(err, result) {
  // Operation complete. result is true if any jobs were
  // cancelled (assuming no error)
});
```

# API

## class Job

`Job` has a bunch of Class methods and properties to help with creating and managing Jobs and getting work for them.

### `Job.setDDP(ddp, [collectionName], [Fiber])`

This class method binds `Job` to a specific instance of `DDPClient`. See [node-ddp-client](https://github.com/oortcloud/node-ddp-client) for more details. Currently it's only possible to use a single DDP connection at a time.

```javascript
var ddp = new DDP({
  host: "127.0.0.1",
  port: 3000,
  use_ejson: true
});

Job.setDDP(ddp);
```

If you will be running multiple DDP connections, then you must run `setDDP()` for each collection using the `collectionName` parameter, to tell `Job` which collection corresponds to which DDP connection:

```javascript
// Provide the name for each collection as a string
// Each named collection may only use one DDP connection
Job.setDDP(ddp1, 'JC1');
Job.setDDP(ddp2, 'JC2'); // Two collections on ddp2 must each register
Job.setDDP(ddp2, 'JC3');
// For convenience, the above two lines may also be expressed in one call:
Job.setDDP(ddp2, ['JC2','JC3']);
```

If you would like to use [Fibers](https://www.npmjs.com/package/fibers) to write non-Meteor node.js in a synchronous style as you can on a Meteor Server, you can enable this support by providing the `Fiber` object to this method, and then running your code within one or more active fibers:

```javascript
Fiber = require('fibers');

Job.setDDP(ddp, Fiber);

Fiber(function () {
   j = new Job('myJob', {...});
   try {
      result = j.save();
   } catch (err) {
      // Do something
   }
});
```


### `Job.getWork(root, type, [options], [callback])`

Get one or more jobs from the job Collection, setting status to `'running'`.

`options`:

* `maxJobs` -- Maximum number of jobs to get. Default `1`  If `maxJobs > 1` the result will be an array of job objects, otherwise it is a single job object, or `undefined` if no jobs were available.

* `workTimeout` -- Tells the server to automatically fail the requested job(s) if more than `workTimeout` milliseconds elapses between updates (`job.progress()`, `job.log()`) from the worker before processing on the job is completed. This is optional, and allows the server to automatically demote and retry running jobs that may never finish because a worker went down or lost connectivity. Default: `undefined`

`callback(error, result)` -- Result will be an array or single value depending on `options.maxJobs`. Optional only on Meteor Server or with Fiber support, in which case errors will throw and the result is the return value.

```javascript
if (Meteor.isServer) {
  job = Job.getWork(  // Job will be undefined or contain a Job object
    'jobQueue',  // name of job Collection
    'jobType',   // type of job to request
    {
      maxJobs: 1 // Default, only get one job, returned as a single object
    }
  );
} else {
  Job.getWork(
    'jobQueue',                 // root name of job Collection
    [ 'jobType1', 'jobType2' ]  // can request multiple types in array
    {
      maxJobs: 5 // If maxJobs > 1, result is an array of jobs
    },
    function (err, jobs) {
      // jobs contains between 0 and maxJobs jobs, depending on availability
      // job type is available as
      if (job[0].type === 'jobType1') {
        // Work on jobType1...
      } else if (job[0].type === 'jobType2') {
        // Work on jobType2...
      } else {
        // Sadness
      }
    }
  );
}
```

### `Job.processJobs(root, type, [options], worker)`

See documentation below for `JobQueue`

### `Job.getJob(root, id, [options], [callback])`

Creates a job object by id from the server job Collection, returns `undefined` if no such job exists.

`options`:

* `getLog` -- If `true`, get the current log of the job. Default is `false` to save bandwidth since logs can be large.

`callback(error, result)` -- `result` is a job object or `undefined`. Optional only on Meteor Server or with Fiber support, in which case errors will throw and the result is the return value.

```javascript
if (Meteor.isServer) {
  job = Job.getJob(  // Job will be undefined or contain a Job object
    'jobQueue',  // name of job Collection
    id,          // job id of type EJSON.ObjectID()
    {
      getLog: false  // Default, don't include the log information
    }
  );
  // Job may be null
} else {
  Job.getJob(
    'jobQueue',    // root name of job Collection
    id,            // job id of type EJSON.ObjectID()
    {
      getLog: true  // include the log information
    },
    function (err, job) {
      if (job) {
        // Here's your job
      }
    }
  );
}
```

### `Job.getJobs(root, ids, [options], [callback])`

Like `Job.getJob` except it takes an array of ids and is much more efficient than calling `job.getJob()` in a loop because it gets Jobs from the server in batches.

### `Job.readyJobs(root, [ids], [options], [callback])`

Like `job.ready()` except it readies a list of jobs by id. It is valid to call `Job.readyJobs()` without `ids` (or with an empty array), in which case all `'waiting'` jobs that are ready to run (any waiting period has passed) and have no dependencies will have their status changed to `'ready'`. This call uses the `force` and `time` options just the same as `job.ready()`. This is  much more efficient than calling `job.ready()` in a loop because it gets Jobs from the server in batches.

### `Job.pauseJobs(root, ids, [options], [callback])`

Like `job.pause()` except it pauses a list of jobs by id and is much more efficient than calling `job.pause()` in a loop because it gets Jobs from the server in batches.

### `Job.resumeJobs(root, ids, [options], [callback])`

Like `job.resume()` except it resumes a list of jobs by id and is much more efficient than calling `job.resume()` in a loop because it gets Jobs from the server in batches.

### `Job.cancelJobs(root, ids, [options], [callback])`

Like `job.cancel()` except it cancels a list of jobs by id and is much more efficient than calling `job.cancel()` in a loop because it gets Jobs from the server in batches.

### `Job.restartJobs(root, ids, [options], [callback])`

Like `job.restart()` except it restarts a list of jobs by id and is much more efficient than calling `job.restart()` in a loop because it gets Jobs from the server in batches.

### `Job.removeJobs(root, ids, [options], [callback])`

Like `job.remove()` except it removes a list of jobs by id and is much more efficient than calling `job.remove()` in a loop because it gets Jobs from the server in batches.

### `Job.startJobServer(root, [options], [callback])`

Starts the server job Collection.

`options`: No options currently

`callback(error, result)` -- Result is true if successful. On Meteor Server or with Fiber support, errors will throw and the return value is the result.

```javascript
Job.startJobServer('jobQueue');  // Callback is optional
```

### `Job.shutdownJobServer(root, [options], [callback])`

Shuts down the server job Collection.

`options`:

* `timeout`: In ms, how long until the server forcibly fails all still running jobs. Default: `60*1000` (1 minute)

`callback(error, result)` -- Result is true if successful.

```javascript
Job.shutdownJobServer(
  'jobQueue',
  {
    timeout: 60000
  }
);  // Callback is optional
```

### `Job.forever`

Constant value used to indicate the count of something should repeat forever.

```javascript
job = new Job('jobQueue', 'jobType', { work: "to", be: "done" })
   .retry({ retries: Job.forever })    // Default for .retry()
   .repeat({ repeats: Job.forever });  // Default for .repeat()
```

### `Job.foreverDate`

Constant value used to indicate a future Date that will never arrive.

```javascript
job = new Job('jobQueue', 'jobType', { work: "to", be: "done" })
   .retry({ until: Job.foreverDate })    // Default for .retry()
   .repeat({ until: Job.foreverDate });  // Default for .repeat()
```

### `Job.jobPriorities`

Valid non-numeric job priorities.

```javascript
Job.jobPriorities = { low: 10, normal: 0, medium: -5,
                      high: -10, critical: -15 };
```

### `Job.jobRetryBackoffMethods`

Valid retry backoff methods.

```javascript
jobRetryBackoffMethods = [ 'constant', 'exponential' ];
```

### `Job.jobStatuses`

Possible states for the status of a job in the job collection.

```javascript
Job.jobStatuses = [ 'waiting', 'paused', 'ready', 'running',
                    'failed', 'cancelled', 'completed' ];
```

### `Job.jobLogLevels`

Valid log levels. If these look familiar, it's because they correspond to some the Bootstrap [context](http://getbootstrap.com/css/#helper-classes) and [alert](http://getbootstrap.com/components/#alerts) classes.

```javascript
Job.jobLogLevels = [ 'info', 'success', 'warning', 'danger' ];
```

### `Job.jobStatusCancellable`

Job status states that can be cancelled.

```javascript
Job.jobStatusCancellable = [ 'running', 'ready', 'waiting', 'paused' ];
```

### `Job.jobStatusPausable`

Job status states that can be paused.

```javascript
Job.jobStatusPausable = [ 'ready', 'waiting' ];
```

### `Job.jobStatusRemovable`

Job status states that can be removed.

```javascript
Job.jobStatusRemovable = [ 'cancelled', 'completed', 'failed' ];
```

### `Job.jobStatusRestartable`

Job status states that can be restarted.

```javascript
Job.jobStatusRestartable = [ 'cancelled', 'failed' ];
```

### `Job.ddpMethods`

Array of the names of all DDP methods used by `Job`

```javascript
Job.ddpMethods = [
    'startJobServer', 'stopJobServer', 'jobRemove', 'jobPause',
    'jobResume', 'jobCancel', 'jobRestart', 'jobSave', 'jobRerun',
    'getWork', 'getJob', 'jobLog', 'jobProgress', 'jobDone',
    'jobFail' ];
```

### `Job.ddpPermissionLevels`

Array of the predefined DDP method permission levels

```javascript
Job.ddpPermissionLevels = [ 'admin', 'manager', 'creator', 'worker' ];
```

### `Job.ddpMethodPermissions`

Object mapping permission levels to DDP method names.

```javascript
Job.ddpMethodPermissions = {
    'startJobServer': ['startJobServer', 'admin'],
    'shutdownJobServer': ['shutdownJobServer', 'admin'],
    'jobRemove': ['jobRemove', 'admin', 'manager'],
    'jobPause': ['jobPause', 'admin', 'manager'],
    'jobResume': ['jobResume', 'admin', 'manager'],
    'jobCancel': ['jobCancel', 'admin', 'manager'],
    'jobRestart': ['jobRestart', 'admin', 'manager'],
    'jobSave': ['jobSave', 'admin', 'creator'],
    'jobRerun': ['jobRerun', 'admin', 'creator'],
    'getWork': ['getWork', 'admin', 'worker'],
    'getJob': ['getJob', 'admin', 'worker'],
    'jobLog': [ 'jobLog', 'admin', 'worker'],
    'jobProgress': ['jobProgress', 'admin', 'worker'],
    'jobDone': ['jobDone', 'admin', 'worker'],
    'jobFail': ['jobFail', 'admin', 'worker']
};
```

## Instances of Job

### `j = new Job(root, type, data)`

Create a new `Job` object.  Data should be reasonably small, if worker requires a lot of data (e.g. video, image or sound files), they should be included by reference (e.g. with a URL pointing to the data, and another to where the result should be saved).

```javascript
job = new Job(  // new is optional
  'jobQueue',   // job collection name
  'jobType',    // type of the job
  { /* ... */ } // Data for the worker, any valid EJSON object
);
```

### `j = new Job(root, jobDoc)`

Make a Job object from a job Collection document. Creates a new `Job` object. This is used in cases where a valid Job document is obtained from another source, such as a database lookup.

```javascript
job = new Job(  // new is optional
  'jobQueue',   // job collection name
  { /* ... */ } // any valid Job document
);
```

### `j.depends([dependencies])`

Adds jobs that this job depends upon (antecedents). This job will not run until these jobs have successfully completed. Defaults to an empty array (no dependencies). Returns `job`, so it is chainable.
Added jobs must have already had `.save()` run on them, so they will have the `_id` attribute that is used to form the dependency. Calling `j.depends()` with a falsy value will clear any existing dependencies for this job.

```javascript
 // job1 and job2 are Job objects, and they both
 // must successfully complete before job will run
job.depends([job1, job2]);
job.depends();  // Clear any dependencies previously added on this job
```

### `j.priority([priority])`

Sets the priority of this job. Can be integer numeric or one of `Job.jobPriorities`. Defaults to `'normal'` priority, which is priority `0`. Returns `job`, so it is chainable.

```javascript
job.priority('high');  // Maps to -10
job.priority(-10);     // Same as above
```

### `j.retry([options])`

Set how failing jobs are rescheduled and retried by the job Collection. Returns `job`, so it is chainable.

`options:`

* `retries` -- Number of times to retry a failing job. Default: `Job.forever`
* `until` -- Keep retrying until this `Date`, or until the number of retries is exhausted, whichever comes first. Default: `Job.foreverDate`. Note that if you specify a value for `until` on a repeating job, it will only apply to the first run of the job. Any repeated runs of the job will use the repeat `until` value for all retries.
* `wait` -- Initial value for how long to wait between attempts, in ms. Default: `300000` (5 minutes)
* `backoff` -- Method to use in determining how to calculate wait value for each retry:
    * `'constant'`:  Always delay retrying by `wait` ms. Default value.
    * `'exponential'`:  Delay by twice as long for each subsequent retry, e.g. `wait`, `2*wait`, `4*wait` ...

`[options]` may also be a non-negative integer, which is interpreted as `{ retries: [options] }`

Note that the above stated defaults are those when `.retry()` is explicitly called. When a new job is created, the default number of `retries` is `0`.

```javascript
job.retry({
  retries: 5,   // Retry 5 times,
  wait: 20000,  // waiting 20 seconds between attempts
  backoff: 'constant'  // wait constant amount of time between each retry
});
```

### `j.repeat([options])`

Set how many times this job will be automatically re-run by the job Collection. Each time it is re-run, a new job is created in the job collection. This is equivalent to running `job.rerun()`. Only `'completed'` jobs are repeated. Failing jobs that exhaust their retries will not repeat. By default, if an infinitely repeating job is added to the job Collection, any existing repeating jobs of the same type will also continue to repeat.  See `option.cancelRepeats` for `job.save()` for more info on how to override this behavior. Returns `job`, so it is chainable.

`options:`

* `repeats` -- Number of times to rerun the job. Default: `Job.forever`
* `until` -- Keep repeating until this `Date`, or until the number of repeats is exhausted, whichever comes first. Default: `Job.foreverDate`
* `wait`  -- How long to wait between re-runs, in ms. Default: `300000` (5 minutes)
* `schedule` -- Repeat using a valid [later.js](https://github.com/bunkat/later) schedule. The first run of this job will occur at the first valid scheduled time unless `.after()` or `.delay()` have been called, in which case it will run at the first scheduled time thereafter. Note: `schedule` and `wait` are mutually exclusive.

`[options]` may also be a non-negative integer, which is interpreted as `{ repeats: [options] }`

Note that the above stated defaults are those when `.repeat()` is explicitly called. When a new job is created, the default number of `repeats` is `0`.

```javascript
job.repeat({
  repeats: 5,   // Rerun this job 5 times,
  wait: 20000   // wait 20 seconds between each re-run.
});

// Using later.js
job.repeat({
  // Note that you need to install the later npm package yourself when running under pure node.js
  schedule: later.parse.text('every 5 mins');   // Rerun this job every 5 minutes
});
```

### `j.delay([milliseconds])`

How long to wait until this job can be run, counting from when it is initially saved to the job Collection. Returns `job`, so it is chainable.

```javascript
job.delay(0);   // Do not wait. This is the default.
```

### `j.after([time])`

`time` is a date object. This sets the time after which a job may be run. It is not guaranteed to run "at" this time because there may be no workers available when it is reached. Returns `job`, so it is chainable.

```javascript
// Run the job anytime after right now. This is the default.
job.after(new Date());
```

### `j.log(message, [options], [callback])`

Add an entry to this job's log. May be called before a new job is saved. `message` must be a string.

`options:`

* `level`: One of `Jobs.jobLogLevels`: `'info'`, `'success'`, `'warning'`, or `'danger'`.  Default is `'info'`.
* `echo`: Echo this log entry to the console. `'danger'` and `'warning'` level messages are echoed using `console.error()` and `console.warn()` respectively. Others are echoed using `console.log()`. If echo is `true` all messages will be echoed. If `echo` is one of the `Job.jobLogLevels` levels, only messages of that level or higher will be echoed.

`callback(error, result)` -- Result is true if logging was successful. When running on Meteor Server or with Fibers, for a saved object the callback may be omitted, and then errors will throw and the return value is the result. If called on an unsaved object, the result is `job` and can be chained.

```javascript
job.log(
  "This is a message",
  {
    level: 'warning'
    echo: true   // Default is false
  },
  function (err, result) {
    if (result) {
      // The log method worked!
    }
  }
);

var verbosityLevel = 'warning';
job.log("Don't echo this", { level: 'info', echo: verbosityLevel } );
```

### `j.progress(completed, total, [options], [cb])`

Update the progress of a running job. May be called before a new job is saved. `completed` must be a number `>= 0` and `total` must be a number `> 0` with `total >= completed`.

`options:`

* `echo`: Echo this progress update to the console using `console.log()`.

`callback(error, result)` -- Result is true if progress update was successful. When running on Meteor Server or with Fibers, for a saved object the callback may be omitted, and then errors will throw and the return value is the result. If called on an unsaved object, the result is `job` and can be chained.

```javascript
job.progress(
  50,
  100,    // Half done!
  {
    echo: true   // Default is false
  },
  function (err, result) {
    if (result) {
      // The progress method worked!
    }
  }
);
```

### `j.save([options], [callback])`

Submits this job to the job Collection. Only valid if this is a new job, or if the job is currently paused in the job Collection. If the job is already saved and paused, then most properties of the job may change (but not all, e.g. the jobType may not be changed.)

`options:`

* `cancelRepeats`: If true and this job is an infinitely repeating job, will cancel any existing jobs of the same job type. This is useful for background maintenance jobs that may get added on each server restart (potentially with new parameters). Default is `false`.

`callback(error, result)` -- Result is true if save was successful. When running on Meteor Server or with Fibers, the callback may be omitted, and then errors will throw and the return value is the result.

```javascript
job.save(
  {
    // Cancel any jobs of the same type,
    // if this job repeats forever.
    // Default: false.
    cancelRepeats: true
  }
);
```
### `j.refresh([options], [callback])`

Refreshes the current job object state with the state on the remote job Collection. Note that if you subscribe to the job Collection, the job documents will stay in sync with the server automatically via Meteor reactivity.

`options:`

* `getLog` -- If true, also refresh the jobs log data (which may be large).  Default: `false`
* `getFailures` -- If true, also refresh the jobs failure results (which may be large).  Default: `false`

`callback(error, result)` -- Result is the Job object if refresh was successful. When running as `Meteor.isServer` or with Fibers, the callback may be omitted and the return value is the result, so in this case this method is chainable and any errors will cause a throw.

```javascript
job.refresh(function (err, result) {
  if (result) {
    // Refreshed
  }
});
```

### `j.done(result, [options], [callback])`

Change the state of a running job to `'completed'`. `result` is any EJSON object.  If this job is configured to repeat, a new job will automatically be cloned to rerun in the future. Result will be saved as an object. If passed result is not an object, it will be wrapped in one.

`options:`

* `repeatId` -- If true, changes the return value of successful call from `true` to be the `_id` of a newly scheduled job if this is a repeating job. Default: `false`

* `delayDeps` -- Integer. If defined, this sets the number of milliseconds before dependent jobs will run. It is equivalent to setting `job.delay(delayDeps)` on each dependent job, with a check to ensure that such jobs will not run sooner than they would have otherwise. Default: undefined.

`callback(error, result)` -- Result is true if completion was successful. When running on Meteor Server or with Fibers, the callback may be omitted, and then errors will throw and the return value is the result.

```javascript
job.done(someResult, { repeatId: true }, function (err, newId) {
  if (newId && newId !== true) {
    // Next repeat job scheduled with _id = newId
  }
});

// Pass a non-object result
job.done("Done!");
// This will be saved as:
// { "value": "Done!" }
```

### `j.fail(error, [options], [callback])`

Cause this job to fail. It's next state depends on how the job's `job.retry()` settings are configured. It will either become `'failed'` or go to `'waiting'` for the next retry. `error` is any EJSON object. Error will be saved as an object. If passed error is not an object, it will be wrapped in one.

`options:`

* `fatal` -- If true, no additional retries will be attempted and this job will go to a `'failed'` state. Default: `false`

`callback(error, result)` -- Result is true if failure was successful (heh). When running on Meteor Server or with Fibers, the callback may be omitted, and then errors will throw and the return value is the result.

```javascript
job.fail(
  {
    reason: 'This job has failed again!',
    code: 44
  }
  {
    fatal: false  // Default case
  },
  function (err, result) {
    if (result) {
      // Status updated
    }
  }
});

// Pass a non-object error
job.fail("Error!");
// This will be saved as:
// { "value": "Error!" }
```

### `j.pause([options], [callback])`

Change the state of a job to `'paused'`. Only `'ready'` and `'waiting'` jobs may be paused. This specifically does nothing to affect running jobs. To stop a running job, you must use `job.cancel()`. Unsaved objects my be paused so that start out in that state when saved.

`options:` -- None currently.

`callback(error, result)` -- Result is true if pausing was successful. When running on Meteor Server or with Fibers, the callback may be omitted, and then errors will throw and the return value is the result.

```javascript
job.pause(function (err, result) {
  if (result) {
    // Status updated
  }
});
```

### `j.resume([options], [callback])`

Change the state of a job from `'paused'` to `'waiting'`.

`options:` -- None currently.

`callback(error, result)` -- Result is true if resuming was successful. When running on Meteor Server or with Fibers, the callback may be omitted, and then errors will throw and the return value is the result.

```javascript
job.resume(function (err, result) {
  if (result) {
    // Status updated
  }
});
```

### `j.ready([options], [callback])`

Change the state of a job to `'ready'`. Any job that is `'waiting'` may be readied. Jobs with unsatisfied dependencies will not be changed to `'ready'` unless the `force` option is used.

`options:`

* `time` -- A `Date` object. If the job was set to run before the specified time, it will be set to `'ready'` now. Default: the current time
* `force` -- Force all remaining dependencies to be satisfied. Default: `false`

`callback(error, result)` -- Result is true if state was changed to ready. When running on Meteor Server or with Fibers, the callback may be omitted, and then errors will throw and the return value is the result.

```javascript
job.ready(
  {
    time: new Date(), // Job.foreverDate would make this unconditional
    force: false
  },
  function (err, result) {
    if (result) {
      // Status updated
    }
  }
);
```

### `j.cancel([options], [callback])`

Change the state of a job to `'cancelled'`. Any job that isn't `'completed'`, `'failed'` or already `'cancelled'` may be cancelled. Cancelled jobs retain any remaining retries and/or repeats if they are later restarted.

`options:`

* `antecedents` -- Also cancel all cancellable jobs that this job depends on.  Default: `false`
* `dependents` -- Also cancel all cancellable jobs that depend on this job.  Default: `true`

`callback(error, result)` -- Result is true if cancellation was successful. When running on Meteor Server or with Fibers, the callback may be omitted, and then errors will throw and the return value is the result.

```javascript
job.cancel(
  {
    antecedents: false,
    dependents: true    // Also cancel all jobs that will never run without this one.
  },
  function (err, result) {
    if (result) {
      // Status updated
    }
  }
);
```

### `j.restart([options], [callback])`

Change the state of a `'failed'` or `'cancelled'` job to `'waiting'` to be retried. A restarted job will retain any repeat count state it had when it failed or was cancelled.

`options:`

* `retries` -- Number of additional retries to attempt before failing with `job.retry()`. Default: `0`. These retries add to any remaining retries already on the job (such as if it was cancelled).
* `until` -- Keep retrying until this `Date`, or until the number of retries is exhausted, whichever comes first. Default: Prior value of `until`. Note that if you specify a value for `until` when restarting a repeating job, it will only apply to the first run of the job. Any repeated runs of the job will use the repeat `until` value for all retries.
* `antecedents` -- Also restart all `'cancelled'` or `'failed'` jobs that this job depends on.  Default: `true`
* `dependents` -- Also restart all `'cancelled'` or `'failed'` jobs that depend on this job.  Default: `false`

`callback(error, result)` -- Result is true if restart was successful. When running on Meteor Server or with Fibers, the callback may be omitted, and then errors will throw and the return value is the result.

```javascript
job.restart(
  {
    antecedents: true,  // Also restart all jobs that must
                        // complete before this job can run.
    dependents: false,
    retries: 0          // Only try one more time. This is the default.
  },
  function (err, result) {
    if (result) {
      // Status updated
    }
  }
);
```

### `j.rerun([options], [callback])`

Clone a completed job and run it again.

`options:`

* `repeats` -- Number of times to repeat the job, as with `job.repeat()`.
* `until` -- Keep repeating until this `Date`, or until the number of repeats is exhausted, whichever comes first. Default: prior value of `until`
* `wait` -- Time to wait between reruns. Default is the existing `job.repeat({ wait: ms }) setting for the job.

`callback(error, result)` -- Result is true if rerun was successful. When running on Meteor Server or with Fibers, the callback may be omitted, and then errors will throw and the return value is the result.

```javascript
job.rerun(
  {
    repeats: 0,         // Only repeat this once. This is the default.
    wait: 60000         // Wait a minute between repeats.
                        // Default is value from job being rerun.
  },
  function (err, result) {
    if (result) {
      // Status updated
    }
  }
);
```

### `j.remove([options], [callback])`

Permanently remove this job from the job collection. The job must be `'completed'`, `'failed'`, or `'cancelled'` to be removed.

`options:` -- None currently.

`callback(error, result)` -- Result is true if removal was successful. When running on Meteor Server or with Fibers, the callback may be omitted, and then errors will throw and the return value is the result.

```javascript
job.remove(function (err, result) {
  if (result) {
    // Job removed from server.
  }
});
```

### `j.type`

Always a string. Returns the type of a job. Useful for when `getWork` or `processJobs` are configured to accept multiple job types. This may not be changed after a job is created.

### `j.data`

Always an object, contains the job data needed by the worker to complete a job of a given type. This may not be changed after a job is created.

### `j.doc`

Always an object, contains the full job document as stored in a JobCollection. This may not be changed after a job is created.

## class JobQueue

JobQueue is similar in spirit to the [async.js](https://github.com/caolan/async) [queue](https://github.com/caolan/async#queue) and [cargo]([queue](https://github.com/caolan/async#cargo)) except that it gets its work from the Meteor jobCollection via calls to `Job.getWork()`

### `q = Job.processJobs(root, type, [options], worker)`

Create a `JobQueue` to automatically get work from the job Collection, and asynchronously call the worker function.

Note, if you are running in a non-Meteor node.js environment with Fiber support, the worker function will not automatically be run within a fiber. You are responsible for setting this up yourself.

`options:`

* `concurrency` -- Maximum number of async calls to `worker` that can be outstanding at a time. Default: `1`
* `payload` -- Maximum number of job objects to provide to each worker, Default: `1` If `payload > 1` the first paramter to `worker` will be an array of job objects rather than a single job object.
* `pollInterval` -- How often to ask the remote job Collection for more work, in ms. Any falsy value for this parameter will completely disable polling (see `q.trigger()` for an alternative way to drive the queue), and any truthy, non-numeric value will yield the default poll interval. Default: `5000` (5 seconds)
* `prefetch` -- How many extra jobs to request beyond the capacity of all workers (`concurrency * payload`) to compensate for latency getting more work.
* `workTimeout` -- When requesting work, tells the server to automatically fail the requested job(s) if more than `workTimeout` milliseconds elapses between updates (`job.progress()`, `job.log()`) from the worker, before processing on the job is completed. This is optional, and allows the server to automatically demote and retry running jobs that may never finish because a worker went down or lost connectivity. Default: `undefined`

`worker(result, callback)`

* `result` -- either a single job object or an array of job objects depending on `options.payload`.
* `callback` -- must be eventually called exactly once when `job.done()` or `job.fail()` has been called on all jobs in result.

```javascript
queue = Job.processJobs(
  'jobQueue',   // name of job Collection
  'jobType',    // type of job to request, can also be an array of job types
  {
    concurrency: 4,
    payload: 1,
    pollInterval: 5000,
    prefetch: 1
  },
  function (job, callback) {
    // Only called when there is a valid job
    job.done();
    callback();
  }
);

// The job queue has methods... See JobQueue documentation for details.
queue.pause();
queue.resume();
queue.shutdown();
```

### `q.pause()`

Pause the JobQueue. This means that no more work will be requested from the job collection, and no new workers will be called with jobs that already exist in this local queue. Jobs that are already running locally will run to completion. Note that a JobQueue may be created in the paused state by running `q.pause()` immediately on the returned new jobQueue.

```javascript
q.pause()
```

### `q.resume()`

Undoes a `q.pause()`, returning the queue to the normal running state.

```javascript
q.resume()
```

### `q.trigger()`

This method manually causes the same action that expiration of the `pollInterval` does internally within JobQueue. This is useful for creating responsive JobQueues that are triggered by a Meteor [observe](http://docs.meteor.com/#/full/observe) or DDP [observe](https://www.npmjs.com/package/ddp) based mechanisms, rather than time based polling.

```javascript
// Simple observe based queue
var q = jc.processJobs(
  // Type of job to request
  // Can also be an array of job types
  'jobType',
  {
    pollInterval: 1000000000, // Don't poll
  },
  function (job, callback) {
    // Only called when there is a valid job
    job.done();
    callback();
  }
);

var observer = ddp.observe("myJobs");
observer.added = function () { q.trigger(); };
```

### `q.shutdown([options], [callback])`

`options:`

* `level` -- May be 'hard' or 'soft'. Any other value will lead to a "normal" shutdown.
* `quiet` -- true or false. False by default, which leads to a "Shutting down..." message on stderr.

`callback()` -- Invoked once the requested shutdown conditions have been achieved.

Shutdown levels:

* `'soft'` -- Allow all local jobs in the queue to start and run to a finish, but do not request any more work. Normal program exit should be possible.
* `'normal'` -- Allow all running jobs to finish, but do not request any more work and fail any jobs that are in the local queue but haven't started to run. Normal program exit should be possible.
* `'hard'` -- Fail all local jobs, running or not. Return as soon as the server has been updated. Note: after a hard shutdown, there may still be outstanding work in the event loop. To exit immediately may require `process.exit()` depending on how often asynchronous workers invoke `'job.progress()'` and whether they die when it fails.

```javascript
q.shutdown({ quiet: true, level: 'soft' }, function () {
  // shutdown complete
});
```

### `q.length()`

Number of tasks ready to run.

### `q.full()`

`true` if all of the concurrent workers are currently running.

### `q.running()`

Number of concurrent workers currently running.

### `q.idle()`

`true` if no work is currently running.
