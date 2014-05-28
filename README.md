meteor-job
======================================

**WARNING** This Package remains under development and the methods described here may change. As of now, there are no unit tests. You have been warned!

## Intro

Meteor Job is a pure Javascript implementation of the `Job` and `JobQueue` classes that form the foundation of the `jobCollection` Atmosphere package for Meteor. This package is used internally by `jobCollection` but you should also use it for any job workers you need to create and run outside of the Meteor environment as pure node.js programs.

Here's a very basic example that ignores authentication and connection error handling:

```js
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
  somejobWorker = function (job, cb) {

    job.log("Some message");

    // Work on job...

    job.progress(50, 100);  // Half done!

    // Work some more...

    if (jobError) {
      job.fail("Some error happened...");
    } else {
      job.done();
    }

    cb(null); // Don't forget!
  };

  // Get jobs of type 'somejob' available in the 'jobPile' jobCollection for somejobWorker
  // .resume() is invoked because new JobQueue instances start out paused.
  workers = Job.processJobs('jobPile', 'somejob', somejobWorker).resume();

});
```

## Installation

`npm install meteor-job`

Someday soon there will be tests...

## Usage

Using meteor-job is straightforward for node.js programs that wish to implement job workers.

First, you need to establish a [DDP connection](https://github.com/oortcloud/node-ddp-client) with the Meteor server hosting the jobCollection you wish to work on.

```js
var DDP = require('ddp');
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

  // You will probably need to authenticate here unless the Meteor
  // server is wide open for unauthenticated DDP Method calls, which
  // it really shouldn't be.
  // See DDP package for information about how to use:

    // ddp.loginWithToken(...)
    // ddp.loginWithEmail(...)
    // ddp.loginWithUsername(...)

  // The result of successfully authenticating will be a valid Meteor authToken.
  ddp.loginWithEmail('user@server.com', `notverysecretpassword`, function (err, response) {
    if (err) throw err;
    authToken = response.token

    // From here we can get to work, as long as the DDP connection is good.
    // See the DDP package for details on DDP auto_reconnect, and handling socket events.

    // Do stuff!!!

  });
}
```

Whew! Okay, so you've got an authenticated DDP connection, and you'd like to get to work, now what?





## API

### class Job

`Job` has a bunch of Class methods and properties to help with creating Jobs and getting work for them.

#### `Job.setDDP()`

#### `Job.processJobs()`

#### `Job.getWork()`

#### `Job.makeJob()`

#### `Job.getJob()`

#### `Job.startJobs()`

#### `Job.stopJobs()`

#### `Job.getJobs()`

#### `Job.pauseJobs()`

#### `Job.resumeJobs()`

#### `Job.cancelJobs()`

#### `Job.restartJobs()`

#### `Job.removeJobs()`

The following Job class attributes define various states and levels used by `jobCollection`

#### `Job.forever`

#### `Job.jobPriorities`

#### `Job.jobStatuses`

#### `Job.jobLogLevels`

#### `Job.jobStatusCancellable`

#### `Job.jobStatusPausable`

#### `Job.jobStatusRemovable`

#### `Job.jobStatusRestartablee`

Objects that are instances of Job

#### `j = new Job()`

#### `j.depends()`

#### `j.priority()`

#### `j.retry()`

#### `j.repeat()`

#### `j.delay()`

#### `j.after()`

#### `j.log()`

#### `j.progress()`

#### `j.save()`

#### `j.refresh()`

#### `j.done()`

#### `j.fail()`

#### `j.pause()`

#### `j.resume()`

#### `j.cancel()`

#### `j.restart()`

#### `j.rerun()`

#### `j.remove()`

### class JobQueue

JobQueue is similar in spirit to the [async.js](https://github.com/caolan/async) [priorityQueue](https://github.com/caolan/async#priorityQueue) except that it gets its work from the Meteor jobCollection via calls to `Job.getWork()`

#### `q = Job.processJobs()`

#### `q.resume()`

#### `q.pause()`

#### `q.shutdown()`

#### `q.length()`

#### `q.full()`

#### `q.running()`

#### `q.idle()`

