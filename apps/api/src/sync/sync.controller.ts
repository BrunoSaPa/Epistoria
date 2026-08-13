import { BadRequestException, Body, Controller, Get, HttpCode, Param, ParseIntPipe, Post, Query } from '@nestjs/common';
import { ApiBearerAuth, ApiQuery, ApiTags } from '@nestjs/swagger';
import { CurrentAuth } from '../auth/auth-context.decorator.js';
import type { AuthContext } from '../auth/auth.types.js';
import { parseSequence } from '../common/time.js';
import { ResolveConflictDto, SyncPushDto } from './sync.dto.js';
import { SyncService } from './sync.service.js';

@ApiTags('synchronization')
@ApiBearerAuth()
@Controller('sync')
export class SyncController {
  constructor(private readonly sync: SyncService) {}

  @Post('push')
  push(@CurrentAuth() auth: AuthContext, @Body() dto: SyncPushDto) {
    return this.sync.push(auth, dto);
  }

  @Get('pull')
  @ApiQuery({ name: 'after', required: false, schema: { type: 'string', pattern: '^[0-9]+$' } })
  @ApiQuery({ name: 'limit', required: false, schema: { type: 'integer', minimum: 1, maximum: 500 } })
  pull(
    @CurrentAuth() auth: AuthContext,
    @Query('after') after: string | undefined,
    @Query('limit', new ParseIntPipe({ optional: true })) limit?: number,
  ) {
    const pageSize = limit ?? 200;
    if (pageSize < 1 || pageSize > 500) {
      throw new BadRequestException('limit must be between 1 and 500');
    }
    return this.sync.pull(auth, parseSequence(after), pageSize);
  }

  @Get('conflicts')
  conflicts(@CurrentAuth() auth: AuthContext) {
    return this.sync.conflicts(auth);
  }

  @Post('conflicts/:id/resolve')
  @HttpCode(200)
  resolve(
    @CurrentAuth() auth: AuthContext,
    @Param('id') id: string,
    @Body() dto: ResolveConflictDto,
  ) {
    return this.sync.resolveConflict(auth, id, dto.replacementEntityId);
  }
}
