<?php

require_once("openmediavault/functions.inc");

\OMV\System\LogFileSpec::registerSpecification("omv-writecache", [
    "filename" => "omv-writecache.log",
    "filepath" => "/var/log/omv-writecache.log",
    // Matches: YYYY-MM-DD HH:MM:SS [LEVEL] EVENT: details
    // 1: timestamp, 2: level, 3: event, 4: details/path
    "regex" => "/^(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2})\s+\[(\w+)\]\s+([^:]+):\s*(.*)$/",
    "columns" => [
        "date" => 1,
        "level" => 2,
        "event" => 3,
        "details" => 4
    ]
]);
