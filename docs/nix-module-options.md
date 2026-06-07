# feed-repeat NixOS Module Options

## services\.feed-repeat\.enable



Whether to enable feed-repeat service\.



*Type:*
boolean



*Default:*

```nix
false
```



*Example:*

```nix
true
```



## services\.feed-repeat\.enableNginx



Whether to enable Nginx for as a server for feed files\.



*Type:*
boolean



*Default:*

```nix
false
```



*Example:*

```nix
true
```



## services\.feed-repeat\.enableSSL



Whether to enable SSL for Nginx\.



*Type:*
boolean



*Default:*

```nix
false
```



*Example:*

```nix
true
```



## services\.feed-repeat\.package



The feed-repeat package\.



*Type:*
package



*Default:*

```nix
"The feed-repeat Nix package provided in this repo."
```



## services\.feed-repeat\.cacheDir



Directory to cache source feed files



*Type:*
absolute path



*Default:*

```nix
"/var/cache/feed-repeat"
```



## services\.feed-repeat\.config



List of feeds to process



*Type:*
list of (submodule)



*Default:*

```nix
[ ]
```



## services\.feed-repeat\.config\.\*\.maxEntryCountPerDomain



Maximum number of entries to select from any single domain (optional)



*Type:*
null or (positive integer, meaning >0)



*Default:*

```nix
null
```



*Example:*

```nix
1
```



## services\.feed-repeat\.config\.\*\.minRunGapDays



Minimum gap in days between successive runs for this feed



*Type:*
unsigned integer, meaning >=0



*Default:*

```nix
1
```



*Example:*

```nix
2
```



## services\.feed-repeat\.config\.\*\.minimumEntryAgeDays



Minimum age in days for entries to be eligible for repetition



*Type:*
unsigned integer, meaning >=0



*Default:*

```nix
7
```



*Example:*

```nix
3
```



## services\.feed-repeat\.config\.\*\.outputFilename



Output filename prefix (without \.atom extension)



*Type:*
non-empty string



*Example:*

```nix
"example-feed"
```



## services\.feed-repeat\.config\.\*\.passthroughNewEntries



Whether to pass through new entries (newer than the last output feed update) alongside repeated entries\.



*Type:*
boolean



*Default:*

```nix
false
```



## services\.feed-repeat\.config\.\*\.repeatedEntryCount



Number of entries to repeat in each run



*Type:*
unsigned integer, meaning >=0



*Default:*

```nix
3
```



*Example:*

```nix
5
```



## services\.feed-repeat\.config\.\*\.saveSourceFeedEntries



Whether to cache the source feed locally



*Type:*
boolean



*Default:*

```nix
false
```



## services\.feed-repeat\.config\.\*\.selectionAlpha



Controls how strongly the weighted selection favors older entries\. Higher values make older entries much more likely to be selected\. Set to 0 for uniform random selection\.



*Type:*
floating point number



*Default:*

```nix
1.0
```



*Example:*

```nix
1.5
```



## services\.feed-repeat\.config\.\*\.sourceFeedUrl



URL of the feed source



*Type:*
non-empty string



*Example:*

```nix
"https://example.com/feed.xml"
```



## services\.feed-repeat\.outputDir



Directory to store output Atom files



*Type:*
absolute path



*Default:*

```nix
"/var/lib/feed-repeat"
```



## services\.feed-repeat\.quiet



Whether to enable quiet logging (only warnings and errors)\.



*Type:*
boolean



*Default:*

```nix
false
```



*Example:*

```nix
true
```



## services\.feed-repeat\.timerOnCalendar



Systemd timer calendar expression for feed processing



*Type:*
string



*Default:*

```nix
"daily"
```



*Example:*

```nix
"2days"
```



## services\.feed-repeat\.userAgent



User-Agent header to send in HTTP requests\. Defaults to “feed-repeat” if not set\.



*Type:*
null or string



*Default:*

```nix
null
```



## services\.feed-repeat\.userName



The username to use for running the feed-repeat service\.



*Type:*
non-empty string



*Default:*

```nix
"feed-repeat"
```



## services\.feed-repeat\.verbose



Whether to enable verbose logging\.



*Type:*
boolean



*Default:*

```nix
false
```



*Example:*

```nix
true
```



## services\.feed-repeat\.virtualHost



The hostname of the feed-repeat server\. This is
used only if Nginx is enabled using the ` enableNginx ` option\.



*Type:*
null or non-empty string



*Default:*

```nix
null
```



## services\.feed-repeat\.virtualHostPath



The path component base URL of the feed-repeat server\. This is
used only if Nginx is enabled using the ` enableNginx ` option\.
Must end with a trailing slash (e\.g\. “/” or “/feeds/”) to avoid
nginx alias path-traversal pitfalls\.



*Type:*
null or non-empty string



*Default:*

```nix
null
```


