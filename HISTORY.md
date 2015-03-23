#### v.1.0.0

* j.startJobs and j.stopJobs have been renamed to j.startJobServer and j.shutdownJobServer respectively. The old versions will now generate deprecation warnings.
* Updated README to reflect name change to job-collection and fix broken links to Atmosphere
* Deprecated Job.makeJob(root, doc) in favor of "new Job(root, doc)" constructor signature.
* Added value getters for job.doc, job.type and job.data.
* Added `jq.trigger()` method to provide a mechanism to trigger `getWork` using an alternative method to `pollInterval`
* j.refresh() is now chainable
* Added Fiber support for non-Meteor node.js clients. See `Job.setDDP(ddp, [Fiber])`
* Job constructor now supports supplying an object for `root` if that object has a string attribute named `root`.

#### v0.0.15

* `.fail()` now takes an error object instead of a string, just like `.done()`
* Bumped coffee-script and chai versions
* Fixed broken tests

#### v0.0.14

* Changed validity check in `setDDP`, since ddp npm package no longer does login.

#### v0.0.13

* Remove job_class.js from .gitignore. It causes problems with npm

#### v0.0.12

* Added `until` option for `job.repeat()`, `job.retry()`, job.restart() and job.rerun().
* Added `job.foreverDate` to indicate a Date that will never come
* Added support for the `created` field in a job document

#### v0.0.11

* Updated documentation to reflect a change in the default value of `cancelRepeats` on `job.save()`

#### v0.0.10

* Added support for new `backoff` option to `job.retry()`. Doc improvements.

#### v0.0.9

* Fixed bug in processJobs that caused crash on Meteor.client side. Doc improvements.

#### v0.0.8

* Fixed case where Meteor.setImmediate wasn't being used when available. Documentation improvements

#### v0.0.7

* Erroneous npm publish... no changes from v0.0.6

#### v0.0.6

* Documentation improvements

#### v0.0.5

* Added links to jobCollection on Atmosphere. Fixed a couple of typos.

#### v0.0.4

* Added class constants for DDP Method names and permission levels.

#### v0.0.3

* Numerous small API refinements. Improved docs. Added unit tests for jobQueue.

#### v0.0.2

* Numerous small API refinements. Improved docs. Added extensive unit tests.

#### v0.0.1

* Changed tons of stuff, added documentation

#### v0.0.0

* Initial version
