def scts(t=None):
    import datetime
    d = t or datetime.datetime.now()
    return "%02d%02d%02d%02d%02d%02d00" % (d.year % 100, d.month, d.day, d.hour, d.minute, d.second)

def pack7(text):
    bits = ''
    for ch in text:
        bits += format(ord(ch), '07b')[::-1]
    out = bytearray()
    for i in range(0, len(bits), 8):
        chunk = bits[i:i+8]
        chunk = chunk.ljust(8, '0')
        out.append(int(chunk[::-1], 2))
    return bytes(out), len(text)

def build(sender, text):
    digits = sender.lstrip('+')
    toa = '91' if sender.startswith('+') else '81'
    if len(digits) % 2:
        digits += 'F'
    swapped = ''.join(digits[i+1] + digits[i] for i in range(0, len(digits), 2))
    ud, udl = pack7(text)
    pdu = ('00' + '04' + '%02X' % len(sender.lstrip('+')) + toa + swapped
           + '00' + '00' + scts() + '%02X' % udl + ud.hex())
    return pdu

if __name__ == '__main__':
    import sys
    print(build(sys.argv[1], sys.argv[2]))
