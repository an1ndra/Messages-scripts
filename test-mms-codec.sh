#!/usr/bin/env bash
# Golden-vector regression for the :mms wire format.
#
# PduComposerTest pins three PDUs octet for octet: an 11-octet M-NotifyResp.ind,
# a 45-octet M-ReadRec.ind and a 115-octet one-part M-Send.req (its To header
# carries the /TYPE=PLMN qualifier). Those assertions
# are the only thing standing between a header-order or length-prefix change and
# a PDU that still parses in-house but is rejected by an MMSC — the parser
# accepts what the composer got wrong, so a round-trip test alone cannot see it.
#
# A renamed or deleted test is the failure mode this script exists to catch: a
# vector that stops being checked still leaves the suite green, so the expected
# octets are read out of the test source, counted, cross-checked against the
# production field codes, and only then run. Nothing here restates the vectors —
# the test file is the single copy.
#
# No emulator: the PDU layer is pure Kotlin.
source "$(dirname "$0")/env.sh"

PASS=0; FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
info() { printf '\n=== %s ===\n' "$*"; }

MODULE="$PROJECT_DIR/mms"
PDU_DIR="$MODULE/src/main/java/com/anindra/messages/mms/pdu"
TEST_SRC="$MODULE/src/test/java/com/anindra/messages/mms/pdu/PduComposerTest.kt"
RESULTS="$MODULE/build/test-results/testDebugUnitTest"
LOG="$TMP/mms-codec-gradle.log"
TEST_CLASS="com.anindra.messages.mms.pdu.PduComposerTest"

NOTIFY="aNotifyRespIsExactlyElevenOctets"
READREC="aReadRecEmitsEveryFieldInAscendingCodeOrder"
SENDREQ="aOnePartSendReqIsPinnedOctetForOctet"

PARSER_CLASS="com.anindra.messages.mms.pdu.PduParserTest"
BARE_CT="aBareConstrainedMediaContentTypeWithNoValueLengthParses"
BARE_ESV="aBareTextStringEncodedValueParses"
EMPTY_ESV="anEmptyEncodedStringValueParsesAsEmpty"
FORGED_LEN="aForgedEncodedStringLengthIsRejectedRatherThanEscaping"

for f in "$TEST_SRC" "$PDU_DIR/MessageType.kt" "$PDU_DIR/HeaderField.kt"; do
  [[ -f "$f" ]] || { printf 'Missing %s\n' "$f"; exit 1; }
done
[[ -x "$PROJECT_DIR/gradlew" ]] || { printf 'No gradlew at %s\n' "$PROJECT_DIR"; exit 1; }

for cand in "$HOME/.local/java/"jdk-21.* "$HOME/tools/jdk21" "$JAVA_HOME"; do
  if [ -x "$cand/bin/java" ]; then export JAVA_HOME="$cand"; break; fi
done

info "Read the golden vectors out of the test source"
while IFS= read -r line; do
  case "$line" in
    '[PASS] '*) pass "${line#'[PASS] '}" ;;
    '[FAIL] '*) fail "${line#'[FAIL] '}" ;;
    'VEC '*) printf '  %s\n' "${line#VEC }" ;;
  esac
done < <(python3 - "$TEST_SRC" "$PDU_DIR/MessageType.kt" "$PDU_DIR/HeaderField.kt" \
                "$NOTIFY" "$READREC" "$SENDREQ" <<'PY'
import re, sys

test_src, type_src, field_src, notify, readrec, sendreq = sys.argv[1:7]
source = open(test_src, encoding='utf-8').read()


def constants(path):
    """Every `const val NAME = <int expr>`, evaluated."""
    out = {}
    for name, expr in re.findall(r'const val (\w+) = (.+)', open(path, encoding='utf-8').read()):
        expr = expr.strip()
        value = None
        if re.fullmatch(r'0x[0-9A-Fa-f]+', expr):
            value = int(expr, 16)
        elif re.fullmatch(r'\d+', expr):
            value = int(expr)
        elif ' or ' in expr or ' shl ' in expr:
            # The version and value-set constants are written as expressions
            # like `(1 shl 4) or 2`; they are small integers, so evaluating is
            # safe here and keeps them from being restated in this script.
            # Kotlin's `or`/`shl` are bitwise, which Python spells `|`/`<<`.
            try:
                value = int(eval(
                    expr.replace(' or ', ' | ').replace(' shl ', ' << '),
                    {'__builtins__': {}}, {}))
            except Exception:
                value = None
        if value is not None:
            out[name] = value
    return out


types = constants(type_src)
fields = constants(field_src)


def vector(name):
    """The octets a named @Test pins, as a list of ints.

    Scoped to that one function's hexOf(...) call, so a hex literal in a
    neighbouring test cannot be swept into this vector.
    """
    start = source.find('fun %s(' % name)
    if start < 0:
        return None
    end = source.find('\n    @Test', start)
    body = source[start:end if end > 0 else len(source)]
    start_call = body.find('hexOf(')
    if start_call < 0:
        return None
    depth, i, literals = 0, start_call, []
    while i < len(body):
        c = body[i]
        if c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                break
        elif c == '"' and depth >= 1:
            j, chunk = i + 1, []
            while j < len(body) and body[j] != '"':
                if body[j] == '\\':
                    j += 1
                chunk.append(body[j])
                j += 1
            literals.append(''.join(chunk))
            i = j
        i += 1
    digits = re.sub(r'[^0-9A-Fa-f]', '', ''.join(literals))
    if not digits or len(digits) % 2:
        return None
    return [int(digits[i:i + 2], 16) for i in range(0, len(digits), 2)]


def show(b):
    return ' '.join('%02X' % x for x in b)


def has_run(b, needle):
    ln = len(needle)
    return any(b[s:s + ln] == needle for s in range(len(b) - ln + 1))


def octet(*names):
    """Field-code / message-type values, resolved from the production tables.

    A name the production code no longer declares aborts rather than being
    skipped: the cross-check is the point, so a renamed constant has to be loud.
    """
    table = fields
    out = []
    for n in names:
        if n in fields:
            out.append(fields[n])
        elif n in types:
            out.append(types[n])
        else:
            print('[FAIL] production constant %s is gone, so this script cannot '
                  'cross-check the vector against it' % n)
            sys.exit(3)
    return out


expected = [(notify, 11, 'M-NotifyResp.ind'),
            (readrec, 45, 'M-ReadRec.ind'),
            (sendreq, 115, 'one-part M-Send.req')]

vectors = {}
for name, want_len, label in expected:
    b = vector(name)
    if b is None:
        print('[FAIL] PduComposerTest has no @Test named %s that pins a hexOf(...) '
              'vector — the %s wire format is no longer guarded' % (name, label))
        continue
    vectors[name] = b
    print('VEC %-44s %s' % (name, show(b)))
    if len(b) != want_len:
        print('[FAIL] %s pins %d octets, not the %d the wire format requires'
              % (name, len(b), want_len))
    else:
        print('[PASS] %s still pins the %d-octet %s vector' % (name, want_len, label))

if len(vectors) == len(expected):
    # M-NotifyResp.ind — the one PDU whose lowest field is Message-Type —
    # opens with its type octet. X-Mms-Content-Type (0x84) closes every header
    # block: receivers stop reading headers at it, so M-Send.req carries it
    # after the transaction id, right before the body, and the M-ReadRec.ind
    # vector (no Content-Type of its own) opens at From (0x89). Both shapes
    # are pinned, along with the MMS 1.2 short-integer form (0x80 | 0x12)
    # rather than a plain 0x12.
    MESSAGE_TYPE = octet('MESSAGE_TYPE')[0]
    VERSION_12 = fields['MMS_VERSION_1_2']
    opening = lambda t: [MESSAGE_TYPE, t, MESSAGE_TYPE + 1, 0x80 | VERSION_12]
    checks = [
        (notify, 0, opening(types['NOTIFYRESP_IND']),
         'M-NotifyResp.ind opens <Message-Type 0x83> <MMS-Version 0x92>'),
        (notify, None, [fields['STATUS'], fields['STATUS_RETRIEVED']],
         'M-NotifyResp.ind carries Status=retrieved'),
        (readrec, None, opening(types['READ_REC_IND']),
         'M-ReadRec.ind carries <Message-Type 0x87> <MMS-Version 0x92>'),
        (readrec, None, [fields['READ_STATUS'], fields['READ_STATUS_READ']],
         'M-ReadRec.ind carries Read-Status=read'),
        (readrec, None, [fields['MESSAGE_ID']],
         'M-ReadRec.ind carries the Message-Id field'),
        (readrec, None, [fields['FROM']],
         'M-ReadRec.ind carries the From field'),
        (sendreq, None, opening(types['SEND_REQ']),
         'M-Send.req carries <Message-Type 0x80> <MMS-Version 0x92>'),
        (sendreq, None, [fields['TO']],
         'M-Send.req addresses its recipient with the To field'),
        (sendreq, None, [fields['TRANSACTION_ID']],
         'M-Send.req carries the Transaction-Id field'),
        (sendreq, None, [fields['CONTENT_TYPE']],
         'M-Send.req declares its multipart Content-Type'),
        (sendreq, None, [fields['FROM']],
         'M-Send.req carries the From field'),
    ]
    for name, offset, needle, label in checks:
        b = vectors[name]
        found = has_run(b, needle)
        if offset is not None and b[:len(needle)] != needle:
            found = False
        if found:
            print('[PASS] %s' % label)
        else:
            print('[FAIL] %s — expected %s in %s' % (label, show(needle), show(b)))

    # A WSP text string is null-terminated, and a missing terminator reads one
    # octet too far — which here would swallow the Read-Status that follows.
    # Both PDUs end on an octet pair that only frames correctly that way: a
    # trailing 0x00 for M-NotifyResp.ind's Transaction-Id, and for M-ReadRec.ind
    # a 0x00 closing the To value immediately before Read-Status.
    for name, label, offset in ((notify, 'M-NotifyResp.ind', -1),
                                (readrec, 'M-ReadRec.ind', -3)):
        if vectors[name][offset] == 0x00:
            print('[PASS] %s closes its last text field with a null terminator' % label)
        else:
            print('[FAIL] %s does not null-terminate its last text field (octet %d '
                  'is 0x%02X, not 0x00); the trailing field is mis-framed'
                  % (label, offset, vectors[name][offset]))

    # The single body entry declares a header length and a data length; if they
    # do not account for exactly the octets that follow, the framing is wrong
    # however plausible the octets look.
    b = vectors[sendreq]
    for i in range(len(b) - 2):
        if b[i + 1] + b[i + 2] + 3 == len(b) - i:
            print('[PASS] the M-Send.req body entry header/data lengths account for '
                  'every octet after the entry count')
            break
    else:
        print('[FAIL] no M-Send.req body entry whose declared lengths sum to the '
              'octets that follow it; the part framing is wrong')
PY
)

info "Run the golden-vector and parser-contract tests"
rm -rf "$RESULTS"
(cd "$PROJECT_DIR" && ./gradlew :mms:testDebugUnitTest --rerun-tasks \
  --tests "$TEST_CLASS.$NOTIFY" \
  --tests "$TEST_CLASS.$READREC" \
  --tests "$TEST_CLASS.$SENDREQ" \
  --tests "$PARSER_CLASS.$BARE_CT" \
  --tests "$PARSER_CLASS.$BARE_ESV" \
  --tests "$PARSER_CLASS.$EMPTY_ESV" \
  --tests "$PARSER_CLASS.$FORGED_LEN") >"$LOG" 2>&1 || true

RESULT_XML="$RESULTS/TEST-$TEST_CLASS.xml"
PARSER_XML="$RESULTS/TEST-$PARSER_CLASS.xml"
if [ ! -f "$RESULT_XML" ] || [ ! -f "$PARSER_XML" ]; then
  fail "the golden-vector tests produced no result file (build or compile failed)"
  grep -E '^e: |error:|FAILURE:|FAILED' "$LOG" | head -20 | sed 's/^/       /'
  printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
  exit $((FAIL > 0))
fi
pass "the golden-vector and parser-contract tests ran"

info "Each named test reported a result"
read -r RAN FAILED_TESTS SKIPPED_TESTS <<<"$(
  python3 - "$RESULT_XML" "$PARSER_XML" "$NOTIFY" "$READREC" "$SENDREQ" \
                "$BARE_CT" "$BARE_ESV" "$EMPTY_ESV" "$FORGED_LEN" <<'PY'
import sys, xml.etree.ElementTree as ET
files, names = sys.argv[1:3], sys.argv[3:]
cases = {}
for f in files:
    for c in ET.parse(f).getroot().iter('testcase'):
        cases[c.get('name')] = c
ran = [n for n in names if n in cases]
bad = [n for n in names if n in cases
       and (cases[n].find('failure') is not None or cases[n].find('error') is not None)]
skip = [n for n in names if n in cases and cases[n].find('skipped') is not None]
print(len(ran), ' '.join(bad) or '-', ' '.join(skip) or '-')
PY
)"
[ "${RAN:-0}" -eq 7 ] && pass "all 7 named tests reported a result" \
  || fail "only ${RAN:-0} of 7 named tests reported a result (a renamed or deleted test would hide here)"
[ "$FAILED_TESTS" = "-" ] && pass "all 7 named tests passed" \
  || fail "failing named test(s): $FAILED_TESTS"
[ "$SKIPPED_TESTS" = "-" ] && pass "no named test was skipped" \
  || fail "skipped named test(s): $SKIPPED_TESTS"

printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
exit $((FAIL > 0))