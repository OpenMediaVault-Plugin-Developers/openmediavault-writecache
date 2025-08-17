<?php

require_once("openmediavault/functions.inc");


\OMV\System\LogFileSpec::registerSpecification("omv-writecache", [
    "filename" => "writecache.log",
    "filepath" => "/var/log/openmediavault/writecache.log",
    // 1: timestamp, 2: event, 3: path, 4: policy (optional)
    "regex" => "/^(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2})\s+(Overlay mounted on|Flushed changes for)\s+(\S+)(?:\s+with policy\s+(\w+))?$/",
    "columns" => [
        "date"   => 1,
        "event"  => 2,
        "path"   => 3,
        "policy" => 4
    ]
]);
