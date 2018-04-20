#!/bin/bash

set -e

IFS='
'
VPPCTL_IN=/tmp/vppctl.in
VPPCTL_OUT=/tmp/vppctl.out

function init {
    touch $VPPCTL_OUT
    mkfifo $VPPCTL_IN
}

function cleanup {
    rm -f $VPPCTL_IN $VPPCTL_OUT
}

function connect {
    IS_IPC=$1
    shift
    if [[ $IS_IPC -eq 1 ]]; then
        SOCKET=$1
        shift
        sudo true # prepare password-less sudo for the next command
        cat $VPPCTL_IN | sudo netcat -U $SOCKET >$VPPCTL_OUT &
    else
        IP=$1
        PORT=$2
        shift 2
    	cat $VPPCTL_IN | netcat $IP $PORT >$VPPCTL_OUT &
    fi
    exec 3>$VPPCTL_IN
}

function vppctl {
    echo > $VPPCTL_OUT
    echo "$@" >&3
    echo "show version" >&3
    until grep -q 'vpp v[0-9][0-9]\.' $VPPCTL_OUT; do
        if [[ $? -ne 1 ]]; then
            break # other error
        fi
        sleep 0.05
    done
    head -n -3 $VPPCTL_OUT
}

function print_packet {
    echo -e "Packet $1:"
    echo -e $2
    echo -e ""
}

function print_help_and_exit {
    echo "Usage: $0  -i <VPP-IF-TYPE> [-a <VPP-ADDRESS>] [-r] [-f <REGEXP> / <SUBSTRING>]"
    echo '   -i <VPP-IF-TYPE> : VPP interface *type* to run the packet capture on (e.g. dpdk-input, virtio-input, etc.)'
    echo '                       - available aliases:'
    echo '                         - af-packet-input: afpacket, af-packet, veth'
    echo '                         - virtio-input: tap (version determined from the VPP runtime config), tap2, tapv2'
    echo '                         - tapcli-rx: tap (version determined from the VPP config), tap1, tapv1'
    echo '                         - dpdk-input: dpdk, gbe, phys*'
    echo '   -a <VPP-ADDRESS> : IP address or hostname of the VPP to capture packets from'
    echo '                      - not supported if VPP listens on a UNIX domain socket' 
    echo '                      - default = 127.0.0.1'
    echo '   -r               : apply filter string (passed with -f) as a regexp expression'
    echo '                      - by default the filter is NOT treated as regexp'
    echo '   -f               : filter string that packet must contain (without -r) or match as regexp (with -r) to be printed'
    echo '                      - default is no filtering'
    exit 1
}

function trace {
    INTERFACE=$1

    while getopts i:a:rf:h option
    do
        case "${option}"
            in
            i) INTERFACE=${OPTARG};;
            a) VPPADDR=${OPTARG};;
            r) IS_REGEXP=1;;
            f) FILTER=${OPTARG};;
            h) print_help_and_exit;;
        esac
    done

    # connect to VPP-CLI
    VPPCONFIG="/etc/vpp/contiv-vswitch.conf"
    PORT=`sed -n 's/.*cli-listen .*:\([0-9]*\)/\1/p' $VPPCONFIG`
    if [[ -z $PORT ]]; then
        IS_IPC=1
        if [[ -n $VPPADDR ]]; then
            echo "VPP listens on a UNIX domain socket and therefore cannot be accessed by IP address."
            exit 2
        fi
        SOCKET=`sed -n 's/.*cli-listen //p' $VPPCONFIG`
        if [[ -z SOCKET ]]; then
            SOCKET="/run/vpp/cli.sock" # default
        fi
    else
        IS_IPC=0
        if [[ -z $VPPADDR ]]; then
            VPPADDR="127.0.0.1" # default
        fi
    fi
    connect $IS_IPC $SOCKET $VPPADDR $PORT

    # afpacket aliases
    if [[ "$INTERFACE" == "afpacket" ]] || [[ "$INTERFACE" == "af-packet" ]] || [[ "$INTERFACE" == "veth" ]]; then
        INTERFACE="af-packet-input"
    fi

    # tapv1 + tapv2 alias
    if [[ "$INTERFACE" == "tap" ]]; then
        # find out the version of the tap used
        if vppctl show interface | grep -q tapcli; then
            INTERFACE="tapcli-rx"
        else
            INTERFACE="virtio-input"
        fi
    fi

    # tapv1 aliases
    if [[ "$INTERFACE" == "tap1" ]] || [[ "$INTERFACE" == "tapv1" ]]; then
        INTERFACE="tapcli-rx"
    fi

    # tapv2 aliases
    if [[ "$INTERFACE" == "tap2" ]] || [[ "$INTERFACE" == "tapv2" ]]; then
        INTERFACE="virtio-input"
    fi

    # dpdk aliases
    if [[ "$INTERFACE" == "dpdk" ]] || [[ "$INTERFACE" == "gbe" ]] || [[ "$INTERFACE" == "phys"* ]]; then
        INTERFACE="dpdk-input"
    fi

    COUNT=0
    while true; do
        vppctl clear trace >/dev/null
        vppctl trace add $INTERFACE 50 >/dev/null

        IDX=0
        while true; do
            TRACE=`vppctl show trace`
            STATE=0
            PACKET=""
            PACKETIDX=0

            for LINE in $TRACE; do
                if [[ $STATE -eq 0 ]]; then
                    # looking for "Packet <number>" of the first unconsumed packet
                    if [[ "$LINE" =~ ^Packet[[:space:]]([0-9]+) ]]; then
                        PACKETIDX=${BASH_REMATCH[1]}
                        if [[ $PACKETIDX -gt $IDX ]]; then
                            STATE=1
                            IDX=$PACKETIDX
                        fi
                    fi
                elif [[ $STATE -eq 1 ]]; then
                    # looking for the start of the packet trace
                    if ! [[ "${LINE}" =~ ^[[:space:]]$ ]]; then
                        # found line with non-whitespace character
                        STATE=2
                        PACKET="$LINE"
                    fi
                else
                    # consuming packet trace
                    if [[ "${LINE}" =~ ^[[:space:]]$ ]]; then
                        # end of the trace
                        if [[ -n "${PACKET// }" ]]; then
                            if ([[ -n $IS_REGEXP ]] && [[ "$PACKET" =~ "$FILTER" ]]) || \
                                ([[ -z $IS_REGEXP ]] && [[ "$PACKET" == *"$FILTER"* ]]); then
                                COUNT=$((COUNT+1))
                                print_packet $COUNT "$PACKET"
                            fi
                        fi
                        PACKET=""
                        STATE=0
                    else
                        PACKET="$PACKET\n$LINE"
                    fi
                fi
            done
            if [[ -n "${PACKET// }" ]]; then
                if ([[ -n $IS_REGEXP ]] && [[ "$PACKET" =~ "$FILTER" ]]) || \
                    ([[ -z $IS_REGEXP ]] && [[ "$PACKET" == *"$FILTER"* ]]); then
                    COUNT=$((COUNT+1))
                    print_packet $COUNT "$PACKET"
                fi
            fi
            if [[ $PACKETIDX -gt 35 ]]; then
                echo -e "\nClearing packet trace (some packets may slip uncaptured)...\n"
                break;
            fi

            sleep 0.2
        done
    done
}

if [[ $# -lt 1 ]]; then
    print_help_and_exit
fi

init
trap cleanup EXIT
trace $@