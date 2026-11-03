import android.content.Context;
import android.content.Intent;
import android.provider.Telephony;

public class InjectSms {
    private static byte[] hex(String s) {
        byte[] out = new byte[s.length() / 2];
        for (int i = 0; i < out.length; i++) {
            out[i] = (byte) Integer.parseInt(s.substring(i * 2, i * 2 + 2), 16);
        }
        return out;
    }

    public static void main(String[] args) throws Exception {
        android.os.Looper.prepareMainLooper();
        byte[] pdu = hex(args[0]);
        String pkg = args.length > 1 ? args[1] : null;
        Object at = Class.forName("android.app.ActivityThread")
                .getMethod("systemMain").invoke(null);
        Context ctx = (Context) at.getClass().getMethod("getSystemContext").invoke(at);
        Intent i = new Intent(Telephony.Sms.Intents.SMS_DELIVER_ACTION);
        i.putExtra("pdus", new byte[][]{pdu});
        i.putExtra("format", "3gpp");
        i.addFlags(0x01000000 /* FLAG_RECEIVER_INCLUDE_BACKGROUND */);
        i.addFlags(Intent.FLAG_INCLUDE_STOPPED_PACKAGES);
        if (pkg != null) i.setPackage(pkg);
        ctx.sendBroadcast(i);
        android.os.SystemClock.sleep(1500);
        System.out.println("sent to " + (pkg == null ? "<default sms app>" : pkg));
    }
}
