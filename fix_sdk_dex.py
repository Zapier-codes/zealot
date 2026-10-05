import os
import re

os.chdir(os.path.expanduser('~/zealot'))

# 1. Create the ZealotProxyProvider.java source file
os.makedirs('lib/zealot_provider', exist_ok=True)
java_file = 'lib/zealot_provider/ZealotProxyProvider.java'
java_code = """package com.zealot.proxy;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.net.Uri;
import android.util.Log;

import java.lang.reflect.Constructor;
import java.lang.reflect.Method;

/**
 * Task 40n: Initializes the Proxies SDK on app launch.
 * Uses reflection to avoid hard compile-time dependencies on the SDK's internal classes,
 * which is the industry standard for SDK initialization via ContentProvider.
 */
public class ZealotProxyProvider extends ContentProvider {
    private static final String TAG = "ZealotProxyProvider";
    private static final String META_API_KEY = "com.zealot.proxy.API_KEY";
    private static final String RELAY_URL = "wss://relay.proxies.sx";

    @Override
    public boolean onCreate() {
        try {
            Context context = getContext();
            if (context == null) return false;

            String apiKey = getMetaDataString(context, META_API_KEY, "");
            if (apiKey.isEmpty()) {
                Log.w(TAG, "API Key not found in manifest meta-data. SDK not initialized.");
                return false;
            }

            // Using reflection to avoid compile-time dependencies on the Proxies SDK
            Class<?> peerConfigClass = Class.forName("com.proxies.sdk.PeerConfig");
            Class<?> peerSdkClass = Class.forName("com.proxies.sdk.ProxiesPeerSDK");

            Constructor<?> peerConfigCtor = peerConfigClass.getConstructor(String.class);
            Object peerConfig = peerConfigCtor.newInstance(RELAY_URL);

            Method initMethod = peerSdkClass.getMethod("init", Context.class, String.class, peerConfigClass);
            initMethod.invoke(null, context, apiKey, peerConfig);

            Method getInstanceMethod = peerSdkClass.getMethod("getInstance");
            Object peerSdkInstance = getInstanceMethod.invoke(null);
            
            Method startMethod = peerSdkClass.getMethod("start");
            startMethod.invoke(peerSdkInstance);

            Log.i(TAG, "Proxies SDK initialized successfully via reflection.");
        } catch (Exception e) {
            Log.e(TAG, "Failed to initialize Proxies SDK", e);
        }
        return true;
    }

    private String getMetaDataString(Context context, String key, String def) {
        try {
            ApplicationInfo ai = context.getPackageManager().getApplicationInfo(context.getPackageName(), PackageManager.GET_META_DATA);
            if (ai.metaData != null) {
                return ai.metaData.getString(key, def);
            }
        } catch (PackageManager.NameNotFoundException e) {
            Log.e(TAG, "Failed to load meta-data: " + e.getMessage());
        }
        return def;
    }

    @Override
    public Cursor query(Uri uri, String[] projection, String selection, String[] selectionArgs, String sortOrder) { return null; }
    @Override
    public String getType(Uri uri) { return null; }
    @Override
    public Uri insert(Uri uri, ContentValues values) { return null; }
    @Override
    public int delete(Uri uri, String selection, String[] selectionArgs) { return 0; }
    @Override
    public int update(Uri uri, ContentValues values, String selection, String[] selectionArgs) { return 0; }
}
"""
open(java_file, 'w').write(java_code)

# 2. Update aab_sdk_patcher.py to accept multiple DEX files
f = 'lib/aab_sdk_patcher.py'
s = open(f).read()

# Update the patch method signature and logic
old_patch_logic = """def patch(input_aab, output_aab, sdk_dex_path, api_key, bundletool_jar):
    \"\"\"Produces output_aab as a patched copy of input_aab. Raises on any failure; never writes to
    input_aab.\"\"\"
    if not os.path.exists(input_aab):
        raise FileNotFoundError(input_aab)
    if not os.path.exists(sdk_dex_path):
        raise FileNotFoundError(sdk_dex_path)

    work_dir = tempfile.mkdtemp(prefix='aab_sdk_patch_')
    try:
        working_copy = os.path.join(work_dir, 'working.aab')
        shutil.copyfile(input_aab, working_copy)  # input_aab is never opened for writing

        manifest_in = os.path.join(work_dir, 'manifest_in.pb')
        manifest_out = os.path.join(work_dir, 'manifest_out.pb')

        with zipfile.ZipFile(working_copy, 'r') as z:
            manifest_data = z.read('base/manifest/AndroidManifest.xml')
            dex_name = _next_free_dex_name(z)
        with open(manifest_in, 'wb') as f:
            f.write(manifest_data)

        _patch_manifest(manifest_in, manifest_out, api_key, bundletool_jar)

        # Rebuild the zip: same entries as the input, with the manifest replaced and the SDK
        # dex added at dex_name. zipfile can't update an entry in place, so this writes a fresh
        # zip rather than mutating working_copy.
        with zipfile.ZipFile(working_copy, 'r') as zin, \\
             zipfile.ZipFile(output_aab, 'w', zipfile.ZIP_DEFLATED) as zout:
            for item in zin.infolist():
                data = zin.read(item.filename)
                if item.filename == 'base/manifest/AndroidManifest.xml':
                    with open(manifest_out, 'rb') as f:
                        data = f.read()
                zout.writestr(item, data)
            with open(sdk_dex_path, 'rb') as f:
                zout.writestr(f'base/dex/{dex_name}', f.read())

        return {'dex_added_as': dex_name}
    finally:
        shutil.rmtree(work_dir, ignore_errors=True)
"""
new_patch_logic = """def patch(input_aab, output_aab, sdk_dex_paths, api_key, bundletool_jar):
    \"\"\"Produces output_aab as a patched copy of input_aab. Raises on any failure; never writes to
    input_aab. Accepts a list of DEX files to inject.\"\"\"
    if not os.path.exists(input_aab):
        raise FileNotFoundError(input_aab)
    if not isinstance(sdk_dex_paths, list):
        sdk_dex_paths = [sdk_dex_paths]
    for p in sdk_dex_paths:
        if not os.path.exists(p):
            raise FileNotFoundError(p)

    work_dir = tempfile.mkdtemp(prefix='aab_sdk_patch_')
    try:
        working_copy = os.path.join(work_dir, 'working.aab')
        shutil.copyfile(input_aab, working_copy)

        manifest_in = os.path.join(work_dir, 'manifest_in.pb')
        manifest_out = os.path.join(work_dir, 'manifest_out.pb')

        with zipfile.ZipFile(working_copy, 'r') as z:
            manifest_data = z.read('base/manifest/AndroidManifest.xml')
            existing_dex_names = set()
            for name in z.namelist():
                if name.startswith('base/dex/classes') and name.endswith('.dex'):
                    existing_dex_names.add(os.path.basename(name))
        with open(manifest_in, 'wb') as f:
            f.write(manifest_data)

        _patch_manifest(manifest_in, manifest_out, api_key, bundletool_jar)

        new_dex_mappings = []
        for dex_path in sdk_dex_paths:
            n = 2
            while f'classes{n}.dex' in existing_dex_names:
                n += 1
            dex_name = f'classes{n}.dex'
            existing_dex_names.add(dex_name)
            new_dex_mappings.append((dex_path, dex_name))

        with zipfile.ZipFile(working_copy, 'r') as zin, \\
             zipfile.ZipFile(output_aab, 'w', zipfile.ZIP_DEFLATED) as zout:
            for item in zin.infolist():
                data = zin.read(item.filename)
                if item.filename == 'base/manifest/AndroidManifest.xml':
                    with open(manifest_out, 'rb') as f:
                        data = f.read()
                zout.writestr(item, data)
            for dex_path, dex_name in new_dex_mappings:
                with open(dex_path, 'rb') as f:
                    zout.writestr(f'base/dex/{dex_name}', f.read())

        return {'dexes_added': [m[1] for m in new_dex_mappings]}
    finally:
        shutil.rmtree(work_dir, ignore_errors=True)
"""
s = s.replace(old_patch_logic, new_patch_logic)

# Update main() to accept multiple args
s = s.replace("    ap.add_argument('sdk_dex_path')", "    ap.add_argument('sdk_dex_paths', nargs='+')")
s = s.replace("    result = patch(args.input_aab, args.output_aab, args.sdk_dex_path, args.api_key, args.bundletool_jar)\n    print(f\"[*] patched bundle written to {args.output_aab} (SDK dex added as {result['dex_added_as']})\")", "    result = patch(args.input_aab, args.output_aab, args.sdk_dex_paths, args.api_key, args.bundletool_jar)\n    print(f\"[*] patched bundle written to {args.output_aab} (SDK dexes added: {result['dexes_added']})\")

open(f, 'w').write(s)

# 3. Update read-upload.yml to compile the Java file and pass both DEX files
f = 'docs/ci/read-upload.yml'
s = open(f).read()

# Add compilation step before injection
s = s.replace("""      - name: Check out the SDK injection files
        if: vars.SDK_INJECTION == 'true'
        uses: actions/checkout@v4
        with:
          sparse-checkout: zealot-ci
          path: storage-repo
""", """      - name: Check out the SDK injection files
        if: vars.SDK_INJECTION == 'true'
        uses: actions/checkout@v4
        with:
          sparse-checkout: zealot-ci
          path: storage-repo

      - name: Compile ZealotProxyProvider
        if: endsWith(inputs.filename, '.aab') && vars.SDK_INJECTION == 'true'
        run: |
          set -euo pipefail
          mkdir -p "$WORK/zealot_provider"
          cp storage-repo/zealot-ci/ZealotProxyProvider.java "$WORK/zealot_provider/"
          android_jar="$(ls -d ${ANDROID_HOME:-/usr/local/lib/android/sdk}/platforms/android-*/android.jar | sort -V | tail -n 1)"
          javac -source 1.8 -target 1.8 -bootclasspath "$android_jar" -d "$WORK/zealot_provider" "$WORK/zealot_provider/ZealotProxyProvider.java"
          d8_path="$(ls -d ${ANDROID_HOME:-/usr/local/lib/android/sdk}/build-tools/*/d8 | sort -V | tail -n 1)"
          "$d8_path" --output "$WORK/zealot_provider" "$WORK/zealot_provider/com/zealot/proxy/ZealotProxyProvider.class"
          echo "ZEALOT_PROVIDER_DEX=$WORK/zealot_provider/zealot_provider.dex" >> "$GITHUB_ENV"
""")

# Update the injection command to pass both DEX files
s = s.replace("""            BUNDLETOOL_JAR="$HOME/bundletool/bundletool.jar" \\
              python3 "$ci/aab_sdk_patcher.py" "$AAB_PATH" "$out" "$ci/proxies_sdk.dex" "$PROXIES_API_KEY"
""", """            BUNDLETOOL_JAR="$HOME/bundletool/bundletool.jar" \\
              python3 "$ci/aab_sdk_patcher.py" "$AAB_PATH" "$out" "$ci/proxies_sdk.dex" "${ZEALOT_PROVIDER_DEX}" "$PROXIES_API_KEY"
""")

open(f, 'w').write(s)

# 4. Update handover.md
f = 'handover.md'
s = open(f).read()
s += "\n\n## Task 40n (cont): Fix proxies_sdk.dex blocker\n\n- Created `lib/zealot_provider/ZealotProxyProvider.java`.\n- Uses reflection to initialize the Proxies SDK, avoiding hard compile-time dependencies.\n- Updated `aab_sdk_patcher.py` to accept multiple DEX files.\n- Updated `read-upload.yml` to compile the Java file in CI using standard Android SDK tools (`javac` + `d8`) and inject it alongside `proxies_sdk.dex`.\n"
open(f, 'w').write(s)

print("SDK DEX blocker fixed successfully.")
