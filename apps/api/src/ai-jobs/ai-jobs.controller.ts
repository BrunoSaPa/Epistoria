import { Body, Controller, Get, HttpCode, Param, Post } from '@nestjs/common';
import { ApiBearerAuth, ApiTags } from '@nestjs/swagger';
import { CurrentAuth } from '../auth/auth-context.decorator.js';
import type { AuthContext } from '../auth/auth.types.js';
import { AIJobsService } from './ai-jobs.service.js';
import { ClaimAIJobDto, CompleteAIJobDto, CreateAIJobDto, FailAIJobDto } from './ai-jobs.dto.js';

@ApiTags('trusted processing queue')
@ApiBearerAuth()
@Controller('ai-jobs')
export class AIJobsController {
  constructor(private readonly jobs: AIJobsService) {}

  @Post()
  create(@CurrentAuth() auth: AuthContext, @Body() dto: CreateAIJobDto) {
    return this.jobs.create(auth, dto);
  }

  @Post('claim')
  @HttpCode(200)
  claim(@CurrentAuth() auth: AuthContext, @Body() dto: ClaimAIJobDto) {
    return this.jobs.claim(auth, dto.leaseSeconds);
  }

  @Get(':id')
  get(@CurrentAuth() auth: AuthContext, @Param('id') id: string) {
    return this.jobs.get(auth, id);
  }

  @Post(':id/complete')
  @HttpCode(200)
  complete(
    @CurrentAuth() auth: AuthContext,
    @Param('id') id: string,
    @Body() dto: CompleteAIJobDto,
  ) {
    return this.jobs.complete(auth, id, dto.artifactEntityId);
  }

  @Post(':id/fail')
  @HttpCode(200)
  fail(@CurrentAuth() auth: AuthContext, @Param('id') id: string, @Body() dto: FailAIJobDto) {
    return this.jobs.fail(auth, id, dto.errorCode, dto.retryable);
  }

  @Post(':id/cancel')
  @HttpCode(200)
  cancel(@CurrentAuth() auth: AuthContext, @Param('id') id: string) {
    return this.jobs.cancel(auth, id);
  }
}

