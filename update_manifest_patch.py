import os

os.chdir(os.path.expanduser('~/zealot'))

# 1. Update ManifestPatch.java to include Foreground Service permissions
f = 'lib/aab_manifest_patch/ManifestPatch.java'
# We will rewrite the file to ensure it has the exact permissions needed.
java_code = """package com.zealot.proxy;

import com.android.aapt.Resources;

/**
 * Task 40n: Patches an AAB's protobuf manifest to add the ZealotProxyProvider
 * and all permissions required by the Proxies SDK (foreground service, network, etc.).
 */
public class ManifestPatch {

    public static void patch(String inputPath, String outputPath, String apiKey) throws Exception {
        Resources.XmlNode root = XmlNode.parseFrom(new java.io.FileInputStream(inputPath));
        Resources.XmlElement rootElement = root.getElement();

        // 1. Add required permissions if they don't exist
        String[] permissions = {
            "android.permission.INTERNET",
            "android.permission.ACCESS_NETWORK_STATE",
            "android.permission.FOREGROUND_SERVICE",
            "android.permission.FOREGROUND_SERVICE_DATA_SYNC", // Android 14+
            "android.permission.POST_NOTIFICATIONS",           // Android 13+
            "android.permission.WAKE_LOCK"
        };

        for (String perm : permissions) {
            if (!hasPermission(rootElement, perm)) {
                Resources.XmlElement permElement = Resources.XmlElement.newBuilder()
                    .setName("uses-permission")
                    .addAttribute(Resources.XmlAttribute.newBuilder()
                        .setName("android:name")
                        .setNamespaceUri("http://schemas.android.com/apk/res/android")
                        .setValue(perm))
                    .build();
                rootElement.addChild(Resources.XmlNode.newBuilder().setElement(permElement).build());
            }
        }

        // 2. Add the Provider to the <application> block
        Resources.XmlElement applicationElement = findApplicationElement(rootElement);
        if (applicationElement != null) {
            if (!hasProvider(applicationElement, "com.zealot.proxy.ZealotProxyProvider")) {
                Resources.XmlElement providerElement = Resources.XmlElement.newBuilder()
                    .setName("provider")
                    .addAttribute(Resources.XmlAttribute.newBuilder()
                        .setName("android:name")
                        .setNamespaceUri("http://schemas.android.com/apk/res/android")
                        .setValue("com.zealot.proxy.ZealotProxyProvider"))
                    .addAttribute(Resources.XmlAttribute.newBuilder()
                        .setName("android:authorities")
                        .setNamespaceUri("http://schemas.android.com/apk/res/android")
                        .setValue("${applicationId}.zealot-proxy"))
                    .addAttribute(Resources.XmlAttribute.newBuilder()
                        .setName("android:exported")
                        .setNamespaceUri("http://schemas.android.com/apk/res/android")
                        .setValue("false"))
                    .addAttribute(Resources.XmlAttribute.newBuilder()
                        .setName("android:enabled")
                        .setNamespaceUri("http://schemas.android.com/apk/res/android")
                        .setValue("true"))
                    .build();

                // Add meta-data for API Key
                Resources.XmlElement metaDataElement = Resources.XmlElement.newBuilder()
                    .setName("meta-data")
                    .addAttribute(Resources.XmlAttribute.newBuilder()
                        .setName("android:name")
                        .setNamespaceUri("http://schemas.android.com/apk/res/android")
                        .setValue("com.zealot.proxy.API_KEY"))
                    .addAttribute(Resources.XmlAttribute.newBuilder()
                        .setName("android:value")
                        .setNamespaceUri("http://schemas.android.com/apk/res/android")
                        .setValue(apiKey))
                    .build();

                providerElement.addChild(Resources.XmlNode.newBuilder().setElement(metaDataElement).build());
                applicationElement.addChild(Resources.XmlNode.newBuilder().setElement(providerElement).build());
            }
        }

        root.writeTo(new java.io.FileOutputStream(outputPath));
    }

    private static boolean hasPermission(Resources.XmlElement rootElement, String permName) {
        for (Resources.XmlNode node : rootElement.getChildList()) {
            if (node.hasElement()) {
                Resources.XmlElement elem = node.getElement();
                if (elem.getName().equals("uses-permission")) {
                    for (Resources.XmlAttribute attr : elem.getAttributeList()) {
                        if (attr.getName().equals("android:name") && attr.getValue().equals(permName)) {
                            return true;
                        }
                    }
                }
            }
        }
        return false;
    }

    private static Resources.XmlElement findApplicationElement(Resources.XmlElement rootElement) {
        for (Resources.XmlNode node : rootElement.getChildList()) {
            if (node.hasElement() && node.getElement().getName().equals("application")) {
                return node.getElement();
            }
        }
        return null;
    }

    private static boolean hasProvider(Resources.XmlElement applicationElement, String providerName) {
        for (Resources.XmlNode node : applicationElement.getChildList()) {
            if (node.hasElement() && node.getElement().getName().equals("provider")) {
                for (Resources.XmlAttribute attr : node.getElement().getAttributeList()) {
                    if (attr.getName().equals("android:name") && attr.getValue().equals(providerName)) {
                        return true;
                    }
                }
            }
        }
        return false;
    }
}
"""
open(f, 'w').write(java_code)

print("ManifestPatch.java updated with Foreground Service permissions.")
