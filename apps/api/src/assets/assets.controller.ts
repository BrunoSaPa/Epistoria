import { Body, Controller, Get, Param, Post } from '@nestjs/common';
import { ApiBearerAuth, ApiTags } from '@nestjs/swagger';
import { CurrentAuth } from '../auth/auth-context.decorator.js';
import type { AuthContext } from '../auth/auth.types.js';
import { AssetsService } from './assets.service.js';
import { ConfirmAssetDto, PrepareAssetDto } from './assets.dto.js';

@ApiTags('encrypted assets')
@ApiBearerAuth()
@Controller('assets')
export class AssetsController {
  constructor(private readonly assets: AssetsService) {}

  @Post('prepare')
  prepare(@CurrentAuth() auth: AuthContext, @Body() dto: PrepareAssetDto) {
    return this.assets.prepare(auth, dto);
  }

  @Post(':id/confirm')
  confirm(
    @CurrentAuth() auth: AuthContext,
    @Param('id') id: string,
    @Body() dto: ConfirmAssetDto,
  ) {
    return this.assets.confirm(auth, id, dto.encryptedByteSize);
  }

  @Get(':id/download')
  download(@CurrentAuth() auth: AuthContext, @Param('id') id: string) {
    return this.assets.download(auth, id);
  }

  @Get(':id')
  status(@CurrentAuth() auth: AuthContext, @Param('id') id: string) {
    return this.assets.status(auth, id);
  }
}

