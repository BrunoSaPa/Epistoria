import { Module } from '@nestjs/common';
import { AIJobsController } from './ai-jobs.controller.js';
import { AIJobsService } from './ai-jobs.service.js';

@Module({ controllers: [AIJobsController], providers: [AIJobsService] })
export class AIJobsModule {}

