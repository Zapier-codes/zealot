package com.zealot.updater;

import java.util.Arrays;
import java.util.Collections;

/**
 * Task 47a: a plain JVM check of the updater's rules (UpdaterRules, UpdateOffer: no Android needed).
 * Run: javac -d <out> lib/zealot_updater/com/zealot/updater/{UpdaterRules,UpdateOffer}.java \
 *        lib/zealot_updater/test/com/zealot/updater/UpdaterRulesCheck.java && java -cp <out> com.zealot.updater.UpdaterRulesCheck
 * Prints one line per check and exits 1 on the first failure.
 */
public final class UpdaterRulesCheck {
    private static int checks;

    private static void ok(boolean cond, String what) {
        checks++;
        if (!cond) {
            System.out.println("FAIL: " + what);
            System.exit(1);
        }
    }

    private static UpdateOffer good() {
        UpdateOffer o = new UpdateOffer();
        o.packageName = "com.example.app";
        o.versionCode = 12;
        o.versionName = "1.2.0";
        o.downloadUrl = "https://zealot.example/download/releases/7";
        o.sha256 = "ab".repeat(32);
        o.sizeBytes = 31238330L;
        o.signingFingerprint = "AB:CD:EF";
        o.minSdk = 26;
        return o;
    }

    private static String refuse(UpdateOffer o, long installed, int sdk) {
        return UpdaterRules.refusal("com.example.app", installed, o, sdk);
    }

    public static void main(String[] args) throws Exception {
        // refusal: the accepted case and each rule that refuses
        ok(refuse(good(), 11, 34) == null, "a complete newer offer is accepted");
        ok(refuse(null, 11, 34) != null, "no offer is refused");
        ok(UpdaterRules.refusal("", 11, good(), 34) != null, "an unknown own package is refused");
        ok(UpdaterRules.refusal("com.other", 11, good(), 34) != null, "an offer for another package is refused");
        UpdateOffer o = good(); o.versionCode = 0;
        ok(refuse(o, 11, 34) != null, "an unreadable version code is refused");
        ok(refuse(good(), 12, 34) != null, "an equal version code is refused");
        ok(refuse(good(), 13, 34) != null, "an older offer is refused (no downgrade)");
        o = good(); o.versionName = "  ";
        ok(refuse(o, 11, 34) != null, "a blank version name is refused");
        o = good(); o.downloadUrl = "http://zealot.example/x";
        ok(refuse(o, 11, 34) != null, "an http download address is refused");
        o = good(); o.downloadUrl = "https://";
        ok(refuse(o, 11, 34) != null, "a bare https:// is refused");
        o = good(); o.sha256 = "";
        ok(refuse(o, 11, 34) != null, "a missing sha256 is refused");
        o = good(); o.sha256 = "ab".repeat(31) + "zz";
        ok(refuse(o, 11, 34) != null, "a non-hex sha256 is refused");
        o = good(); o.sizeBytes = 0;
        ok(refuse(o, 11, 34) != null, "a missing size is refused");
        o = good(); o.signingFingerprint = " : ";
        ok(refuse(o, 11, 34) != null, "an empty fingerprint is refused");
        o = good(); o.minSdk = 35;
        ok(refuse(o, 11, 34) != null, "a min SDK above the device is refused");
        o = good(); o.minSdk = 0;
        ok(refuse(o, 11, 21) == null, "an offer with no min SDK is accepted");
        o = good(); o.minSdk = 34;
        ok(refuse(o, 11, 34) == null, "a min SDK equal to the device is accepted");

        // hex and fingerprints
        ok(UpdaterRules.normalizeHex("SHA256:AB:cd ef").equals("abcdef"), "normalizeHex strips prefix, colons and spaces and lowercases");
        ok(UpdaterRules.normalizeHex(null).isEmpty(), "normalizeHex(null) is empty");
        ok(UpdaterRules.isSha256Hex("A".repeat(64)) && UpdaterRules.isSha256Hex("f".repeat(64)), "64 hex digits pass");
        ok(!UpdaterRules.isSha256Hex("a".repeat(63)) && !UpdaterRules.isSha256Hex("g".repeat(64)) && !UpdaterRules.isSha256Hex(null), "63 digits, non-hex and null fail");
        ok(UpdaterRules.sharesFingerprint(Arrays.asList("AB:CD"), Arrays.asList("x", "abcd")), "fingerprints match across case and separators");
        ok(!UpdaterRules.sharesFingerprint(Arrays.asList("abcd"), Arrays.asList("abce")), "different fingerprints do not match");
        ok(!UpdaterRules.sharesFingerprint(null, Arrays.asList("abcd")) && !UpdaterRules.sharesFingerprint(Arrays.asList("abcd"), null), "null never matches");
        ok(!UpdaterRules.sharesFingerprint(Arrays.asList(""), Collections.singletonList("")), "empty never matches empty");

        // a real SHA-256 of known bytes (abc)
        ok(UpdaterRules.certSha256("abc".getBytes("UTF-8")).equals("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"), "certSha256 of 'abc'");

        // https
        ok(UpdaterRules.isHttps("https://a.b") && UpdaterRules.isHttps("HTTPS://a.b") && !UpdaterRules.isHttps("http://a.b") && !UpdaterRules.isHttps(null), "isHttps");

        // the start-up gap
        long h = 60L * 60L * 1000L;
        ok(UpdaterRules.checkDue(0L, 1000L), "never checked: due");
        ok(!UpdaterRules.checkDue(1000L, 1000L + 5 * h), "checked 5h ago: not due");
        ok(UpdaterRules.checkDue(1000L, 1000L + 6 * h), "checked 6h ago: due");
        ok(UpdaterRules.checkDue(10_000_000L, 5_000L), "a clock that went backwards: due");

        // coexistence
        ok(UpdaterRules.isStoreInstaller("com.vythera.vyxelapps", "com.vythera.vyxelapps"), "the store is recognised");
        ok(UpdaterRules.isStoreInstaller("b.store", "a.store, b.store"), "a list entry with a space is recognised");
        ok(!UpdaterRules.isStoreInstaller("com.android.vending", "com.vythera.vyxelapps"), "Google Play is not a store that checks for us");
        ok(!UpdaterRules.isStoreInstaller(null, "a") && !UpdaterRules.isStoreInstaller("", "a"), "no installer: not a store");

        // notification id: stable, in its own range
        ok(UpdaterRules.notificationId("com.example.app") == UpdaterRules.notificationId("com.example.app"), "notification id is stable");
        ok((UpdaterRules.notificationId("com.example.app") & 0xff000000) == 0x5a000000, "notification id is in the 0x5a range");

        // failure sentences
        ok(UpdaterRules.failureReason(UpdaterRules.STATUS_FAILURE_CONFLICT, null).contains("different key"), "a conflict names the signing key");
        ok(UpdaterRules.failureReason(UpdaterRules.STATUS_FAILURE_STORAGE, "no space").contains("no space"), "Android's own message is kept");
        ok(!UpdaterRules.failureReason(UpdaterRules.STATUS_FAILURE, "").contains("Android said"), "no message, no 'Android said'");
        ok(UpdaterRules.failureReason(99, null).contains("could not be installed"), "an unknown status gets the generic sentence");

        System.out.println("PASS: " + checks + " checks");
    }
}
