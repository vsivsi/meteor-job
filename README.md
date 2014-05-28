### meteor-job

**WARNING** This Package remains under development and the methods described here may change. As of now, there are no unit tests. You have been warned!

#### Intro

Meteor Job is a pure Javascript implementation of the `Job` and `JobQueue` classes that form the foundation of the `jobCollection` Atmosphere package for Meteor. This package is used by `jobCollection` but you should also use it for any job workers you need to create and run outside of the Meteor environment (as pure node.js programs.)

Here's a very basic example that ignores authentication and connection error handling:

```js
var DDP = require('ddp');
var Job = require('meteor-job')

var ddp = new DDP({
  host: "127.0.0.1",
  port: 3000,
  use_ejson: true
});

var root = 'queue';

Job.setDDP(ddp);

ddp.connect(function (err) {
  if (err) throw err;

  # Worker function for jobs of type 'some_job'
  some_jobWorker = function (job, cb) {
    job.log("Some message");
    # Work on job...
    job.progress(50, 100);  # Half done!
    # Work some more...
    job.done();
    cb(null);
  };

  workers = Job.processJobs(root, 'some_job', some_jobWorker).resume();

});
```
