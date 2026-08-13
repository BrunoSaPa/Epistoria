import { Module } from '@nestjs/common';
import { AssetsController } from './assets.controller.js';
import { AssetsService } from './assets.service.js';
import { ObjectStorage } from './object-storage.js';
import { S3ObjectStorage } from './s3-object-storage.service.js';

@Module({
  controllers: [AssetsController],
  providers: [
    AssetsService,
    S3ObjectStorage,
    { provide: ObjectStorage, useExisting: S3ObjectStorage },
  ],
})
export class AssetsModule {}

