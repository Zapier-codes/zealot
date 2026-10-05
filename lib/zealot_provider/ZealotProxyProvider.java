package com.zealot.proxy;

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
 *
 * Task 40n (fix, 2026-10-05): the class and method names below were wrong (guessed as
 * com.proxies.sdk.* with a one-arg PeerConfig(String) constructor). The real SDK, read
 * from proxies_sdk.dex with androguard this session, is Kotlin under sx.proxies.peer.*:
 *   - sx.proxies.peer.ProxiesPeerSDK          (the outer class; init/getInstance are
 *                                               @JvmStatic, so they are plain static
 *                                               methods on this class, not on a nested
 *                                               Companion object)
 *   - sx.proxies.peer.ProxiesPeerSDK$Config   (a 5-arg data class: apiUrl, relayUrl,
 *                                               userId, onEarningsUpdate, onStatusChange
 *                                               -- confirmed from the constructor's own
 *                                               field-assignment order, not guessed; the
 *                                               last two are Kotlin callbacks typed
 *                                               kotlin.jvm.functions.Function1 and are
 *                                               optional -- null is accepted, confirmed
 *                                               from the synthetic default-arguments
 *                                               constructor, which fills them with null
 *                                               when omitted)
 * Still reflection-only on purpose: Function1's Class is loaded by name too, so this
 * file has no compile-time dependency on the SDK or the Kotlin stdlib and compiles with
 * only the Android SDK on the classpath, exactly as before.
 * Not run end to end on a device -- the class/method/field names are read directly from
 * the real proxies_sdk.dex, not guessed, but no emulator or device test was done this
 * session (none is available in this sandbox).
 */
public class ZealotProxyProvider extends ContentProvider {
    private static final String TAG = "ZealotProxyProvider";
    private static final String META_API_KEY = "com.zealot.proxy.API_KEY";
    private static final String SDK_CLASS = "sx.proxies.peer.ProxiesPeerSDK";
    private static final String CONFIG_CLASS = "sx.proxies.peer.ProxiesPeerSDK$Config";
    private static final String FUNCTION1_CLASS = "kotlin.jvm.functions.Function1";
    private static final String API_URL = "https://api.proxies.sx/v1";
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
            Class<?> function1Class = Class.forName(FUNCTION1_CLASS);
            Class<?> configClass = Class.forName(CONFIG_CLASS);
            Class<?> sdkClass = Class.forName(SDK_CLASS);

            // Config(apiUrl, relayUrl, userId, onEarningsUpdate, onStatusChange); the last
            // two are optional callbacks, null is the same as the SDK's own default.
            Constructor<?> configCtor = configClass.getConstructor(
                String.class, String.class, String.class, function1Class, function1Class);
            Object config = configCtor.newInstance(API_URL, RELAY_URL, null, null, null);

            // init/getInstance are @JvmStatic on the outer class, not on a Companion object.
            Method initMethod = sdkClass.getMethod("init", Context.class, String.class, configClass);
            initMethod.invoke(null, context, apiKey, config);

            Method getInstanceMethod = sdkClass.getMethod("getInstance");
            Object peerSdkInstance = getInstanceMethod.invoke(null);

            Method startMethod = sdkClass.getMethod("start");
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
