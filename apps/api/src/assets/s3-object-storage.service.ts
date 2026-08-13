import { Injectable } from '@nestjs/common';
import { GetObjectCommand, HeadObjectCommand, PutObjectCommand, S3Client } from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
import { environment } from '../config/environment.js';
import { ObjectStorage, type PreparedObjectUpload } from './object-storage.js';

@Injectable()
export class S3ObjectStorage extends ObjectStorage {
  private readonly config = environment();
  private readonly client = new S3Client({
    endpoint: this.config.s3.endpoint,
    region: this.config.s3.region,
    forcePathStyle: this.config.s3.forcePathStyle,
    credentials: {
      accessKeyId: this.config.s3.accessKeyId,
      secretAccessKey: this.config.s3.secretAccessKey,
    },
  });

  async prepareUpload(objectKey: string, byteSize: number): Promise<PreparedObjectUpload> {
    const contentType = 'application/octet-stream';
    const command = new PutObjectCommand({
      Bucket: this.config.s3.bucket,
      Key: objectKey,
      ContentType: contentType,
      ContentLength: byteSize,
    });
    return {
      url: await getSignedUrl(this.client, command, { expiresIn: this.config.s3.presignTtlSeconds }),
      headers: { 'content-type': contentType, 'content-length': String(byteSize) },
      expiresInSeconds: this.config.s3.presignTtlSeconds,
    };
  }

  async prepareDownload(objectKey: string): Promise<{ url: string; expiresInSeconds: number }> {
    const command = new GetObjectCommand({ Bucket: this.config.s3.bucket, Key: objectKey });
    return {
      url: await getSignedUrl(this.client, command, { expiresIn: this.config.s3.presignTtlSeconds }),
      expiresInSeconds: this.config.s3.presignTtlSeconds,
    };
  }

  async size(objectKey: string): Promise<number | null> {
    try {
      const result = await this.client.send(
        new HeadObjectCommand({ Bucket: this.config.s3.bucket, Key: objectKey }),
      );
      return result.ContentLength ?? null;
    } catch (error) {
      const status = (error as { $metadata?: { httpStatusCode?: number } }).$metadata?.httpStatusCode;
      if (status === 404) return null;
      throw error;
    }
  }
}

