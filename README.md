### meteor-job

**WARNING** This Package remains under development and the methods described here may change. As of now, there are no unit tests. You have been warned!

#### Intro

Meteor Job is a pure Javascript implementation of the `Job` and `JobQueue` classes that form the foundation of the `jobCollection` Atmosphere package for Meteor. This package is used by `jobCollection` but you should also use it for any job workers you need to create and run outside of the Meteor environment (as pure node.js programs.)

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
      job.fail(jobError);
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
