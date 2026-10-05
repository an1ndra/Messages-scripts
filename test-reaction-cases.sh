#!/usr/bin/env bash
# Verifies when the reaction picker may appear and when it must not.
#
# Should appear: a normal 1:1 message, your own message, a group message.
# Must not appear: a concealed locked message, an alphanumeric sender ID (which
# cannot receive replies), a blocked number, or while more than one message is
# selected (the picker is a single-message affordance).
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

TS=$(( $(date +%s) * 1000 ))
sql() { echo "$1" | adb_ shell "run-as $PKG sqlite3 databases/messages.db"; }

A="+15550011111"; B="+15550022222"; C="+15550033333"; C2="+15550033334"
D="+15550044444"; E="ALPHA-1234"; F="+15550055555"; G="+15550066666"
ADDRS="$A $B $C $D $F $G"

cleanup() {
    for n in $ADDRS "$C2" "$E"; do
        sql "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$n');"
        sql "DELETE FROM conversation_recipients WHERE conversation_id IN (SELECT id FROM conversations WHERE address='$n');"
        sql "DELETE FROM conversations WHERE address='$n';"
    done
    sql "DELETE FROM blocked_numbers WHERE number='$F';"
}
trap cleanup EXIT

seed() { # addr name body is_me locked
    sql "INSERT INTO conversations(address,name,snippet,timestamp,last_is_me) VALUES('$1','$2','$3',$TS,$4);"
    sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type,locked) SELECT id,'$3',$TS,$4,'received','text',$5 FROM conversations WHERE address='$1';"
}

# Long-press the bubble containing $2 in the chat for $1; sets PICKER=1/0.
press_and_check() { # addr press_text
    adb_ shell am force-stop "$PKG"; sleep 1
    adb_ shell am start -n "$ACT" --es open_conversation_address "$1" >/dev/null 2>&1; sleep 4
    local c; c=$(center_of_contains "$2") || return 2
    local x=${c% *} y=${c#* }
    adb_ shell input swipe $x $y $((x + 2)) $y 1200; sleep 2
    if ui_has "👍"; then PICKER=1; else PICKER=0; fi
    return 0
}

expect() { # want(1/0) label
    if [ "$PICKER" = "$1" ]; then
        [ "$1" = "1" ] && ok "$2: picker shown" || ok "$2: picker hidden"
    else
        [ "$1" = "1" ] && bad "$2: picker MISSING" || bad "$2: picker SHOWN but should not be"
    fi
}

info "Seed the cases"
cleanup
seed "$A" "CaseNormal" "case-normal" 0 0
seed "$B" "CaseOwn"    "case-own"    1 0
seed "$C" "CaseGroup"  "case-group"  0 0
sql "INSERT INTO conversation_recipients(conversation_id,address) SELECT id,'$C2' FROM conversations WHERE address='$C';"
seed "$D" "CaseLocked" "case-locked" 0 1
seed "$E" "CaseAlpha"  "case-alpha"  0 0
seed "$F" "CaseBlocked" "case-blocked" 0 0
sql "INSERT OR REPLACE INTO blocked_numbers(number,timestamp) VALUES('$F',$TS);"
seed "$G" "CaseMulti"  "case-multi-1" 0 0
sql "INSERT INTO messages(conversation_id,body,timestamp,is_me,status,media_type) SELECT id,'case-multi-2',$((TS+1000)),0,'received','text' FROM conversations WHERE address='$G';"

info "1. Normal 1:1 message -> picker expected"
press_and_check "$A" "case-normal" && expect 1 "normal"

info "2. Your own (outgoing) message -> picker expected"
press_and_check "$B" "case-own" && expect 1 "own message"

info "3. Group conversation -> picker expected"
press_and_check "$C" "case-group" && expect 1 "group"

info "4. Concealed locked message -> picker must NOT appear"
press_and_check "$D" "@Lock" && expect 0 "locked"

info "5. Alphanumeric sender ID (no replies possible) -> picker must NOT appear"
press_and_check "$E" "case-alpha" && expect 0 "alphanumeric"

info "6. Blocked number -> picker must NOT appear"
press_and_check "$F" "case-blocked" && expect 0 "blocked"

info "7. Two messages selected -> picker must NOT appear"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" --es open_conversation_address "$G" >/dev/null 2>&1; sleep 4
M1=$(center_of_contains "case-multi-1"); M2=$(center_of_contains "case-multi-2")
if [ -z "$M1" ] || [ -z "$M2" ]; then
    bad "multi: could not find both messages"
else
    x1=${M1% *}; y1=${M1#* }
    adb_ shell input swipe $x1 $y1 $((x1 + 2)) $y1 1200; sleep 1.5
    ui_has "👍" && FIRST=1 || FIRST=0
    x2=${M2% *}; y2=${M2#* }
    adb_ shell input tap $x2 $y2; sleep 1.5
    if ui_has "👍"; then PICKER=1; else PICKER=0; fi
    [ "$FIRST" = "1" ] || bad "multi: picker missing for the first single press"
    expect 0 "multi-select"
fi

info "8. Locked message once unlocked -> picker expected"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" --es open_conversation_address "$D" >/dev/null 2>&1; sleep 4
LM=$(center_of "@Lock")
if [ -z "$LM" ]; then
    bad "unlocked: @Lock not found"
else
    lx=${LM% *}; ly=${LM#* }
    adb_ shell input swipe $lx $ly $((lx + 2)) $ly 1200; sleep 1.5
    MO=$(center_of_contains "More options") || bad "unlocked: selection toolbar missing"
    if [ -n "$MO" ]; then
        adb_ shell input tap $MO; sleep 1
        U=$(center_of "Unlock")
        if [ -z "$U" ]; then
            bad "unlocked: Unlock item missing"
        else
            adb_ shell input tap $U; sleep 2
            BM=$(center_of_contains "case-locked")
            if [ -z "$BM" ]; then
                bad "unlocked: body not revealed"
            else
                bx=${BM% *}; by=${BM#* }
                adb_ shell input swipe $bx $by $((bx + 2)) $by 1200; sleep 2
                if ui_has "👍"; then PICKER=1; else PICKER=0; fi
                expect 1 "unlocked message"
            fi
        fi
    fi
fi

info "9. Deselect back to one -> reacting acts on the remaining selection"
adb_ shell am force-stop "$PKG"; sleep 1
adb_ shell am start -n "$ACT" --es open_conversation_address "$G" >/dev/null 2>&1; sleep 4
A1=$(center_of_contains "case-multi-1"); B1=$(center_of_contains "case-multi-2")
if [ -z "$A1" ] || [ -z "$B1" ]; then
    bad "deselect: could not find both messages"
else
    x1=${A1% *}; y1=${A1#* }; x2=${B1% *}; y2=${B1#* }
    adb_ shell input swipe $x1 $y1 $((x1 + 2)) $y1 1200; sleep 1.5   # select A
    adb_ shell input tap $x2 $y2; sleep 1.5                          # add B (2 selected)
    adb_ shell input tap $x1 $y1; sleep 1.5                          # deselect A (B selected)
    P=$(center_of_top "👍")
    if [ -z "$P" ]; then
        bad "deselect: picker missing after deselecting one"
    else
        adb_ shell input tap $P; sleep 2
        RA=$(sql "SELECT reactions FROM messages WHERE body='case-multi-1';" | tr -d '\r')
        RB=$(sql "SELECT reactions FROM messages WHERE body='case-multi-2';" | tr -d '\r')
        if [ -z "$RA" ] && [ "$RB" = "👍:1" ]; then
            ok "reaction landed on the remaining selection, not the deselected message"
        else
            bad "reaction targeted the wrong message (A='$RA' B='$RB')"
        fi
    fi
fi

echo ""
info "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
