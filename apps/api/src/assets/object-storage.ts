export interface PreparedObjectUpload {
  url: string;
  headers: Record<string, string>;
  expiresInSeconds: number;
}

export abstract class ObjectStorage {
  abstract prepareUpload(objectKey: string, byteSize: number): Promise<PreparedObjectUpload>;
  abstract prepareDownload(objectKey: string): Promise<{ url: string; expiresInSeconds: number }>;
  abstract size(objectKey: string): Promise<number | null>;
}

