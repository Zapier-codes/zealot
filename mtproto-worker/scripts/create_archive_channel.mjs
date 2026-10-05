import { TelegramClient, Api } from 'teleproto';
import { StringSession } from 'teleproto/sessions/index.js';

function requireEnv(name) {
  const v = process.env[name];
  if (!v) {
    console.error(`Missing required env var ${name}`);
    process.exit(1);
  }
  return v;
}

const apiId = Number(requireEnv('TELEGRAM_API_ID'));
const apiHash = requireEnv('TELEGRAM_API_HASH');
const sessionString = requireEnv('TELEGRAM_SESSION_STRING');
const title = process.argv[2] || 'Zealot Release Archive';
const about =
  process.argv[3] ||
  'Private cold-storage channel for Zealot release-pipeline artifacts. Not for humans to post in.';

const client = new TelegramClient(new StringSession(sessionString), apiId, apiHash, {
  connectionRetries: 5,
});

async function main() {
  console.log('Connecting...');
  await client.connect();

  console.log(`Creating channel "${title}"...`);
  const result = await client.invoke(
    new Api.channels.CreateChannel({
      title,
      about,
      megagroup: false,
      broadcast: true,
    })
  );

  const chat = result.chats?.[0];
  if (!chat) {
    console.error('CreateChannel did not return a chat — raw result:', JSON.stringify(result, null, 2));
    process.exit(1);
  }

  const archiveChatId = `-100${chat.id}`;
  console.log('\nChannel created.');
  console.log('Title:  ', chat.title);
  console.log('Raw id: ', chat.id.toString());
  console.log('\nSet this on Render:');
  console.log(`TELEGRAM_ARCHIVE_CHAT_ID=${archiveChatId}`);

  await client.disconnect();
}

main().catch((err) => {
  console.error('Failed:', err.message);
  process.exit(1);
});
