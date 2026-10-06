// Task 40n-a: edits an app bundle's binary-protobuf AndroidManifest.xml (base/manifest/AndroidManifest.xml
// inside the .aab) using the com.android.aapt.Resources.XmlNode/XmlElement/XmlAttribute classes that
// bundletool-all-*.jar already bundles (frameworks/base's aapt2 Resources.proto, compiled). No separate
// aapt2/.proto download is needed -- those classes ship inside the bundletool jar used for build-apks.
//
// Adds, inside <application>:
//   <provider android:name="com.zealot.proxy.ZealotProxyProvider"
//             android:authorities="${applicationId}.zealot-proxy" android:exported="false">
//     <meta-data android:name="com.zealot.proxy.API_KEY" android:value="<api_key>"/>
//   </provider>
// and, as top-level children of <manifest>, each permission the SDK needs that the app lacks (INTERNET,
// ACCESS_NETWORK_STATE, FOREGROUND_SERVICE, FOREGROUND_SERVICE_DATA_SYNC, POST_NOTIFICATIONS, WAKE_LOCK).
//
// Per the 40m design: the provider class ships precompiled inside the SDK dex and reads its API key from
// this meta-data value, rather than generated smali (that was 40j's APK-only approach). As of this session
// proxies_sdk.dex (checked into the repo) has no com/zealot/* classes, so that precompiled provider class
// does not exist yet -- flagged in the handover, not fixed here. This tool only edits the manifest; see
// aab_sdk_patcher.py for the dex-injection and repack steps.
import com.android.aapt.Resources.XmlNode;
import com.android.aapt.Resources.XmlElement;
import com.android.aapt.Resources.XmlAttribute;
import java.io.*;
import java.nio.file.*;

public class ManifestPatch {
    private static final String ANDROID_NS = "http://schemas.android.com/apk/res/android";

    public static void main(String[] args) throws Exception {
        if (args.length < 1) usage();
        String cmd = args[0];
        if (cmd.equals("dump")) {
            if (args.length != 2) usage();
            byte[] data = Files.readAllBytes(Paths.get(args[1]));
            XmlNode root = XmlNode.parseFrom(data);
            System.out.println(root.toString());
        } else if (cmd.equals("patch")) {
            if (args.length != 4) usage();
            String inPath = args[1];
            String outPath = args[2];
            String apiKey = args[3];

            byte[] data = Files.readAllBytes(Paths.get(inPath));
            XmlNode root = XmlNode.parseFrom(data);
            XmlElement.Builder manifestBuilder = root.getElement().toBuilder();

            XmlNode.Builder appNodeBuilder = findChildBuilder(manifestBuilder, "application");
            if (appNodeBuilder == null) {
                throw new RuntimeException("no <application> element found in manifest");
            }
            XmlElement.Builder appBuilder = appNodeBuilder.getElementBuilder();

            if (hasNamedChild(appBuilder, "provider", "com.zealot.proxy.ZealotProxyProvider")) {
                throw new RuntimeException("manifest already has a ZealotProxyProvider <provider> -- refusing to add a second one");
            }

            XmlElement metaDataEl = XmlElement.newBuilder()
                .setName("meta-data")
                .addAttribute(attr("name", "com.zealot.proxy.API_KEY"))
                .addAttribute(attr("value", apiKey))
                .build();

            XmlElement providerEl = XmlElement.newBuilder()
                .setName("provider")
                .addAttribute(attr("name", "com.zealot.proxy.ZealotProxyProvider"))
                .addAttribute(attr("authorities", "${applicationId}.zealot-proxy"))
                .addAttribute(attr("exported", "false"))
                .addChild(XmlNode.newBuilder().setElement(metaDataEl).build())
                .build();
            appBuilder.addChild(XmlNode.newBuilder().setElement(providerEl).build());
            appNodeBuilder.setElement(appBuilder.build());

            // Permissions the Proxies SDK needs (INTERNET and network state; foreground service for its
            // background work, plus the Android 14+ data-sync type; notifications on 13+; wake lock).
            // Each one is added only if the app does not already declare it.
            String[] permissions = {
                "android.permission.INTERNET",
                "android.permission.ACCESS_NETWORK_STATE",
                "android.permission.FOREGROUND_SERVICE",
                "android.permission.FOREGROUND_SERVICE_DATA_SYNC",
                "android.permission.POST_NOTIFICATIONS",
                "android.permission.WAKE_LOCK"
            };
            for (String perm : permissions) {
                if (!hasNamedChild(manifestBuilder, "uses-permission", perm)) {
                    XmlElement permEl = XmlElement.newBuilder()
                        .setName("uses-permission")
                        .addAttribute(attr("name", perm))
                        .build();
                    manifestBuilder.addChild(XmlNode.newBuilder().setElement(permEl).build());
                }
            }

            XmlNode newRoot = root.toBuilder().setElement(manifestBuilder.build()).build();
            try (FileOutputStream out = new FileOutputStream(outPath)) {
                newRoot.writeTo(out);
            }
            System.out.println("patched manifest written to " + outPath);
        } else {
            usage();
        }
    }

    private static XmlAttribute attr(String name, String value) {
        return XmlAttribute.newBuilder().setNamespaceUri(ANDROID_NS).setName(name).setValue(value).build();
    }

    private static XmlNode.Builder findChildBuilder(XmlElement.Builder parent, String tagName) {
        for (int i = 0; i < parent.getChildCount(); i++) {
            XmlNode child = parent.getChild(i);
            if (child.hasElement() && child.getElement().getName().equals(tagName)) {
                return parent.getChildBuilder(i);
            }
        }
        return null;
    }

    // True if parent has a child <tagName android:name="nameValue">.
    private static boolean hasNamedChild(XmlElement.Builder parent, String tagName, String nameValue) {
        for (int i = 0; i < parent.getChildCount(); i++) {
            XmlNode child = parent.getChild(i);
            if (!child.hasElement()) continue;
            XmlElement el = child.getElement();
            if (!el.getName().equals(tagName)) continue;
            for (XmlAttribute a : el.getAttributeList()) {
                if (a.getName().equals("name") && a.getValue().equals(nameValue)) return true;
            }
        }
        return false;
    }

    private static void usage() {
        System.err.println("usage: ManifestPatch dump <manifest.pb>");
        System.err.println("       ManifestPatch patch <in.pb> <out.pb> <api_key>");
        System.exit(1);
    }
}
