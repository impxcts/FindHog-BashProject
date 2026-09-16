# findhog.sh
# CSCI 344 Shell Programming Summer 2026 Bash Project by Impxcts
## Description 

This script checks what is currently using up CPU and memory on the system at that current moment.
This will work on both Linux and Mac (it auto-detects which one you're on, since they do have different commands for memory stats). No
login or any special permissions are needed, it just reads normal process info that any user can see. 

Two modes:
- `snapshot`: one-time check of current resource usage. 
- `monitor`: takes multiple snapshots over time and tracks which processes keep showing up as "hogs" vs. just spiking once 

## Usage 

```

./findhog.sh snapshot 
./findhog.sh monitor <interval> <reps>
```

Ex. `./findhog.sh monitor 5 6` will take 6 snapshots, 5 seconds apart 

Running with no arguments, a bad mode, or bad arguments (i.e. a negative interval) prints a usage message and exits. 


## Exit Codes Breakdown 

- `0` = success
- `1` = something failed at runtime (ex. missing command, couldn't write file, etc.)
- `2` = bad usage (ex. wrong args, unknown mode)

## Testing 

No setup needed! Just run it: 
```
chmod +x findhog.sh
./findhog.sh snapshot 
./findhog.sh monitor 2 3
```

To check/examine exit codes:
```
./findhog.sh badmode 
echo $?
```

Reports will be saved to a `reports/` folder that the script will create automatically. 

