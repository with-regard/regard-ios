# iOS client for Regard

http://www.withregard.io

## Usage

Copy the Regard.h and Regard.m files from the [Tracker](https://github.com/with-regard/regard-ios/tree/master/RegardTest/Tracker) folder into your project.

Create a new property list file called '[Regard-Settings.plist](https://github.com/with-regard/regard-ios/blob/master/RegardTest/Regard-Settings.plist)' and add it to your project. This should contain two settings: 'Organization' and 'Product', which should correspond to the project you have registered on the withregard website.

To track an event:

    #import "Regard.h"
    
    ...
    
    [Regard track: @"an-event" properties: @{ "some-value": "something" }]

Note that by default, applications are in an opted-out state where no events will be recorded. There are three functions to control this:

    [Regard optIn];             // Opts in the current user
    [Regard optOut];            // Opts out the current user
    [Regard optInByDefault];    // Opts in the current user if this is the first time they've used the app
