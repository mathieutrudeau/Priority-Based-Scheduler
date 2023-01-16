#!/bin/bash
set -u

declare -rx PROCESS_FILE="/var/asg4/processes.csv"
declare -rx DELIMITER=','
declare -rix AGING_FREQUENCY=2
declare -Arx FIELDNAMES=(   [pid]=0 [tid]=1 [priority]=2 [remainingTime]=3 \
                            [availTime]=4 [burstTime]=5 [agedPriority]=6 \
                                                        [numAgingSkips]=7 [remainingBurstTime]=8 \
                                                        )
declare -rx IO_BLOCKTIME=6
declare -rx QUANTUM=150
declare -rx HW_CS_TIME=8
declare -rx LW_CS_TIME=2
declare -rix NUM_PROCESSES=`wc -l $PROCESS_FILE | egrep -o '^[^ ]* '`
declare -arx PROCESS_INDEXES=(`seq 0 $(( $NUM_PROCESSES - 1 ))`)
declare -rx NUMFIELDS=$(head -n 1 $PROCESS_FILE | egrep -o , | wc -l)

declare -a _processes

# Get all the processes that we need to schedule.
function readFile(){
        readarray _processes < $PROCESS_FILE        # Transfer the processes info into an array.
        initializeCalculatedFields                  # Initialize all our calculated field values.
}

# Get a specific field for a certain process.
function getField(){ 
        local resultVar_=$1                                      # Variable for which we give the field value.
        local procIdx_=$2                                        # Index of process.
        local fieldName_=$3                                      # Name of field to return. 
        
        local -i fieldIndex=${FIELDNAMES[$fieldName_]}           # Index of field to return. 
        local field=${_processes[$procIdx_]}                     # Get all fields of the process.                                    
        for (( a=0; a<${fieldIndex}; a++ )); do                  # Remove all fields we do not need.
            field=${field#*$DELIMITER}
        done

        field=${field%%$DELIMITER*}                              # Remove all remaining fields.
        eval $resultVar_="'$field'"                              # Return the value of the remaining field.
}

# Set a value for chosen field in a certain process.
function setField(){
        local procIdx_=$1                                       # Process Index.
        local fieldName_=$2                                     # Name of field to set.
        local value_=$3                                         # Value to set to the field.
       
        local p=${_processes[$procIdx_]}                        # Retrieve process info.
        local i=${FIELDNAMES[$fieldName_]}                      # Get index of field.
        local arr=(${p//,/ })                                   # Transfer process from string to array.
        arr[$i]=$value_                                         # Change the field value.
        p=${arr[*]}                                             # Save the array as string.
        p=${p// /,}  
        _processes[$procIdx_]=$p                                # Save the changes for that field.
}

# Initialize all the calculated fields for all the processes.
function initializeCalculatedFields() {
        local prio=0                                            
        local burst=0                                           

        for i in ${PROCESS_INDEXES[@]}; do                      # Go through all the processes.
            getField prio $i 'priority'                         
            setField $i 'agedPriority' $prio                    # Aged priority equals priority because it is not yet aged.
            setField $i 'numAgingSkips' 0                       # No aging has occured for now.
            getField burst $i 'burstTime'                       
            setField $i 'remainingBurstTime' $burst             # The remaining burst time is equal to burst time.
        done
}

# Get the remaining time for all processes to complete.
function getRemainingTime(){
        local timeSumVal_=$1
        local -i timeSum=0
        local getRemTime=0

        for i in ${PROCESS_INDEXES[@]}; do                      # Go through all the processes.
            getField getRemTime $i 'remainingTime'                 
            timeSum=$timeSum+$getRemTime                           # Add their remaining times to the sum.
        done

        eval $timeSumVal_="'$timeSum'"                                     # Return the sum of all remaining times.
}

# Returns an array with all the eligible processes index or -1 if there is none.
function getEligibleProcesses(){
       local currentTime_=$1
       local eligibleProcesses=()
       local -i remainingTime=0
       local -i availTime=0
  
       for (( i=0; i<${#PROCESS_INDEXES[@]}; i++ )); do         # Go through all the processes.
            getField remainingTime $i 'remainingTime'           # Get the process remaining time.
            getField availTime $i 'availTime'                   # Get the process available time.
            if [ $remainingTime -gt 0 ] && [ $availTime -le $currentTime_ ]; then                   
                    eligibleProcesses+=($i)                     # The process is eligible, so save its index.
            fi
       done
       if [ ${#eligibleProcesses[@]} -gt 0 ]; then
            echo ${eligibleProcesses[@]}
       else
            echo "-1"                                           # No eligible Process
       fi
}

# Returns the index of the next process that should be run, or -1 if there is none.
function getNextProcess(){
       local currentTime_=$1
       local prevProcess_=$2
       local nextProcessVal_=$3
       local currPrio=0
       local currBurstTime=0
       local prio=0
       local burstTime=0
       local -i nextProcess=-1
       local eligibleProcesses=$( getEligibleProcesses $currentTime_ )
       eligibleProcesses=(${eligibleProcesses// / })
       local -i processesNum=${#eligibleProcesses[@]}
 
        # Get the eliglible process that has the highest priority.
        
       if [ ${eligibleProcesses[0]} -ne -1 ]; then
           for (( i=0; i<$processesNum; i++ )); do
                getField prio ${eligibleProcesses[$i]} 'agedPriority'
                getField burstTime ${eligibleProcesses[$i]} 'remainingBurstTime'
                if [ $prio -gt $currPrio ] || [[ $prio -eq $currPrio && $burstTime -lt $currBurstTime ]]; then
                   if [ $processesNum -gt 1 ] && [ ${eligibleProcesses[$i]} -eq $prevProcess_ ]; then
                        nextProcess=$nextProcess
                   else
                        currPrio=$prio
                        currBurstTime=$burstTime
                        nextProcess=${eligibleProcesses[$i]}
                   fi
                fi
           done
       fi
       ageProcesses $currentTime_ $nextProcess
       eval $nextProcessVal_="'$nextProcess'"
}

# Runs a process, and returns the time it took to run.
function runProcess(){
        local runTimeVal_=$1
        local processIdx_=$2
        local currentTime_=$3
        local remainingTime=0
        local burstTime=0
        local remBurstTime=0
        local prio=0
        local newPrio=0
        local currPID=0
        local currTID=0
        local availTime=0
        local -i runTime=$QUANTUM
        local opEnd=$currentTime_
        local status=""

        # Get necessary fields
        getField remainingTime $processIdx_ 'remainingTime'
        getField burstTime $processIdx_ 'burstTime'
        getField remBurstTime $processIdx_ 'remainingBurstTime'
        getField prio $processIdx_ 'agedPriority'
        getField newPrio $processIdx_ 'priority'
        getField currPID $processIdx_ 'pid'
        getField currTID $processIdx_ 'tid'
        getField availTime $processIdx_ 'availTime' 

         # Get the runTime
        if [ $remBurstTime -lt $runTime ]; then
            runTime=$remBurstTime
        fi
        if [ $remainingTime -lt $runTime ]; then
            runTime=$remainingTime
        fi
       
        ((opEnd+=runTime))
        ((currentTime_++))
        
        # Get the status of the process
        case "$runTime" in
        $remBurstTime)
            status="Status: Blocking I/O"
            ;;
        $QUANTUM)
            status="Status: Quantum Expired"
            ;;
        *)                                                                                                                                                                                                                                               status="Status: Terminated"
            ;;
        esac

        printf "\n"
        printf "%0s %5s %7s" "start[" "$currentTime_], end[" "$opEnd], pid[" "$currPID], tid[" "$currTID], priority[" "$prio], runtime[" "$runTime], availTime[" "$availTime], remaining time[" "$remainingTime], burst length [" "$remBurstTime].  " "$status"

         # Set remaining time and availTime
        ((remainingTime-=runTime))
        ((remBurstTime-=runTime))

        if [ $remBurstTime -eq 0 ]; then
            remBurstTime=$burstTime
            availTime=$currentTime_
            ((availTime+=$runTime))
            ((availTime+=IO_BLOCKTIME))
        fi

        setField $processIdx_ 'remainingTime' $remainingTime
        setField $processIdx_ 'remainingBurstTime' $remBurstTime
        setField $processIdx_ 'availTime' $availTime
        setField $processIdx_ 'agedPriority' $newPrio
        setField $processIdx_ 'numAgingSkips' 0

        # Age the processes that were not run
        #ageProcesses $currentTime_ $processIdx_ 

        eval $runTimeVal_="'$runTime'"
}

function displayStats(){
        local lw_csNum=$1
        local hw_csNum=$2
        local idleTime=$3
        local totalTime=$4
        local lw_csTime=$(( lw_csNum*LW_CS_TIME ))
        local hw_csTime=$(( hw_csNum*HW_CS_TIME ))
        local cpuUtil=$(bc <<< "scale=2 ;(100-(100*$idleTime/$totalTime))") 
        local cpuTime=$(bc <<< "scale=2 ; (100-(100*($idleTime+$lw_csTime+$hw_csTime)/$totalTime))")

        printf "\n"
        echo "-----------------------------------------------------------------------------------------------------------------------------------------------------------------"
        printf "%0s %20s " "CPU Utilization (100 - (idle / in use)) " ":" "${cpuUtil}%"
        printf "\n"
        printf "%0s %26s %6d" "# of lightweight context switches " ":" "$lw_csNum"
        printf "\n"
        printf "%0s %26s %6d" "# of heavyweight context switches " ":" "$hw_csNum"
        printf "\n"
        printf "%0s %28s %6d" "Lightweight context switch time " ":" "$lw_csTime"
        printf "\n"
        printf "%0s %28s %6d" "Heavyweight context switch time " ":" "$hw_csTime"
        printf "\n"
        printf "%0s %4s " "% CPU time spent processing (i.e. not CS'ing, not idle) " ":" "${cpuTime}%" 
        printf "\n"
}

function ageProcesses(){
        local time_=$1
        local processRunning_=$2
        local eligibleProc=$( getEligibleProcesses $time_ )
        eligibleProc=(${eligibleProc// / })
        local -i processesNum=${#eligibleProc[@]}
        local ageSkips=0
        local agedPrio=0
        local processIdx=-1

        # Age all the eligible Processe that were not run.
        if [ ${eligibleProc[0]} -ne -1 ]; then
            for (( i=0; i<$processesNum; i++ )); do
                processIdx=${eligibleProc[$i]}
                if [ $processIdx -ne $processRunning_ ]; then
                    getField ageSkips $processIdx 'numAgingSkips'
                    getField agedPrio $processIdx 'agedPriority'
                    ((ageSkips++))

                    if [ $ageSkips -eq $AGING_FREQUENCY ]; then
                        ((agedPrio++))
                        ageSkips=0
                    fi

                    setField $processIdx 'numAgingSkips' $ageSkips
                    setField $processIdx 'agedPriority' $agedPrio
                fi
            done
        fi
}

function goIdle(){
    local idleTimeVal_=$1
    local nextProcessVal_=$2
    local startTime_=$3
    local nextProcess=-1
    local proc=0
    local prevProcess=-1
    local currentTime=$startTime_
    local remainingTime=0
    getRemainingTime remainingTime

    # Get the next process until its not -1
    while [ $nextProcess -eq -1 ]; do
       ((currentTime++))
       getNextProcess $currentTime $prevProcess proc
       nextProcess=$proc
       prevProcess=$nextProcess
    done

    ((currentTime--))

    printf "\n"
    printf "%7s %5s"  "$startTime_.." "$currentTime" ": ********** IDLE **********, Total time remaining (all threads): $remainingTime."
    
    ((currentTime-=startTime_))

    eval $idleTimeVal_="'$currentTime'"
    eval $nextProcessVal_="'$nextProcess'"
}

function switchContext(){
    local csTimeVal_=$1
    local startTime_=$2
    local prevIdx_=$3
    local currIdx_=$4
    local prevPID=-1
    local prevTID=-1
    local currPID=-1
    local currTID=-1
    local currentTime=$startTime_

    getField currPID $currIdx_ 'pid'
    getField currTID $currIdx_ 'tid'

    if [ $prevIdx_ -ne -1 ]; then 
        getField prevPID $prevIdx_ 'pid'
        getField prevTID $prevIdx_ 'tid'
    fi

    printf "\n"
    ((currentTime--))

    # LW if pid is the same, else hw context switch
    if [ $currPID -ne $prevPID ]; then
        ((currentTime+=HW_CS_TIME))
        printf "%0s %5s %7s" "start[" "$startTime_], end[" "$currentTime], status: HW context switch"
    else
        ((currentTime+=LW_CS_TIME))
        printf "%0s %5s %7s" "start[" "$startTime_], end[" "$currentTime], status: LW context switch"
    fi

    ((currentTime-=startTime_))
    
    eval $csTimeVal_="'$currentTime'"
}

function scheduleProcesses(){   
    local currentTime=0
    local nextProcess=-1
    local prevProcess=-1
    local process=-1
    local opTime=0
    local remTime=0
    local contextLoaded=false
    local lw_cs=0
    local hw_cs=0
    local idleTime=0
    local proc=0

    getRemainingTime remTime

    while [ $remTime -gt 0 ]; do
        getNextProcess $currentTime $prevProcess proc
        nextProcess=$proc
        
        # The cpu goes idle
        if [ $nextProcess -eq -1 ]; then
            goIdle opTime process $currentTime 
            ((opTime++))
            ((currentTime+=opTime))
            ((idleTime+=opTime))
            nextProcess=$process
            if [ $nextProcess -eq $prevProcess ]; then
                ((currentTime--))
            fi
        fi

        # Is the pcb loaded on the cpue
        if [ $nextProcess -ne $prevProcess ]; then
            contextLoaded=false
        else
            contextLoaded=true
        fi

        # Context is not on cpu, change the context
        if [ "$contextLoaded" = false ]; then
           switchContext opTime $currentTime $prevProcess $nextProcess
           contextLoaded=true
           if [ $opTime -lt $LW_CS_TIME ]; then
               ((lw_cs++))
           else
               ((hw_cs++))
           fi
           ((currentTime+=opTime))
        fi
        
        # Run the process once its loaded
        if [ "$contextLoaded" = true ]; then
            prevProcess=$nextProcess
            runProcess opTime $nextProcess $currentTime
            ((currentTime+=opTime))
            ((currentTime++))
        fi

        getRemainingTime remTime
        printf "\n"
        printf "Total time remaining (all threads): $remTime"
    done
    displayStats $lw_cs $hw_cs $idleTime $currentTime
}

readFile
scheduleProcesses

exit 1



