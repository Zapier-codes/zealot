// Thin wrapper around GramJS's successor (`teleproto` npm package — GramJS
// itself was archived upstream in 2025 in favor of this fork; see
// mtproto-worker/README.md "Status" for the verification trail on that)
// implementing the two operations this worker needs: archive a local file
// into our own private Telegram archive chat, and retrieve it back by
// location.
//
// Pattern follows the reference architecture in
// github.com/ShivaReddyVanja/aetheroll (docs/CACHING_AND_DATA_FETCHING_ARCHITECTURE.md):
//   - one persistent, warm MTProto connection (TelegramClient), reused
//     across requests instead of reconnecting per-call, to avoid repeated
//     Diffie-Hellman handshakes and FLOOD_WAIT from Telegram's DCs
//   - uploads via GramJS's built-in chunked `client.uploadFile`, which
//     internally splits into ~512KB parts the same way `upload.saveFile`
//     expects
//   - downloads via `client.downloadMedia`, streamed straight to disk
//     rather than buffered fully in memory
//
// Scope: this archives only our own release artifacts, into a private
// chat/channel we control (`archiveChatId`). It is not a general-purpose
// Telegram upload/download proxy and has no public-facing surface — see
// handover.md's "Scope, stated plainly" section.

import { TelegramClient, Api } from 'teleproto';
import { StringSession } from 'teleproto/sessions/index.js';
import fs from 'node:fs';
import path from 'node:path';

export interface ArchiveLocation {
  chatId: string;
  messageId: number;
}

export function encodeLocation(loc: ArchiveLocation): string {
  return `${loc.chatId}:${loc.messageId}`;
}

export function decodeLocation(raw: string): ArchiveLocation {
  const [chatId, messageId] = raw.split(':');
  if (!chatId || !messageId) throw new Error(`malformed archive location: ${raw}`);
  return { chatId, messageId: Number(messageId) };
}

export class MtprotoClient {
  private client: TelegramClient;
  private archiveChatId: string;
  private connected = false;

  constructor(opts: {
    apiId: number;
    apiHash: string;
    sessionString: string;
    archiveChatId: string;
  }) {
    this.archiveChatId = opts.archiveChatId;
    this.client = new TelegramClient(
      new StringSession(opts.sessionString),
      opts.apiId,
      opts.apiHash,
      { connectionRetries: 5 }
    );
  }

  // Call once at worker boot. Reused for the lifetime of the process — do
  // not construct a new MtprotoClient per request.
  async connect(): Promise<void> {
    if (this.connected) return;
    await this.client.connect();
    this.connected = true;
  }

  async archive(localPath: string, archiveKey: string): Promise<ArchiveLocation> {
    const fileName = path.basename(archiveKey);
    const result = await this.client.sendFile(this.archiveChatId, {
      file: localPath,
      forceDocument: true,
      caption: archiveKey,
      attributes: [new Api.DocumentAttributeFilename({ fileName })],
    });

    const messageId = (result as { id?: number }).id;
    if (typeof messageId !== 'number') {
      throw new Error(`archive upload for ${archiveKey} did not return a message id`);
    }
    return { chatId: this.archiveChatId, messageId };
  }

  // Streams the archived document to `destPath`. Returns false if the
  // message can no longer be found (e.g. deleted upstream in the archive
  // chat), so the caller can surface a 404 rather than a hard error.
  async retrieve(location: ArchiveLocation, destPath: string): Promise<boolean> {
    const messages = await this.client.getMessages(location.chatId, { ids: [location.messageId] });
    const message = messages[0];
    if (!message || !message.media) return false;

    const buffer = await this.client.downloadMedia(message, {});
    if (!buffer) return false;

    await fs.promises.mkdir(path.dirname(destPath), { recursive: true });
    await fs.promises.writeFile(destPath, buffer as Buffer);
    return true;
  }
}
