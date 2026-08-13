import { Body, Controller, Delete, Get, Headers, HttpCode, Param, Post } from '@nestjs/common';
import { ApiBearerAuth, ApiTags } from '@nestjs/swagger';
import { CurrentAuth } from './auth-context.decorator.js';
import { AuthService } from './auth.service.js';
import type { AuthContext } from './auth.types.js';
import { BootstrapDto, DeviceTokenResponseDto, EnrollDeviceDto } from './auth.dto.js';
import { Public } from './public.decorator.js';

@ApiTags('authentication')
@Controller('auth')
export class AuthController {
  constructor(private readonly auth: AuthService) {}

  @Public()
  @Post('bootstrap')
  bootstrap(
    @Headers('x-bootstrap-secret') secret: string | undefined,
    @Body() dto: BootstrapDto,
  ): Promise<DeviceTokenResponseDto> {
    return this.auth.bootstrap(secret, dto);
  }

  @ApiBearerAuth()
  @Post('devices')
  enroll(@CurrentAuth() auth: AuthContext, @Body() dto: EnrollDeviceDto) {
    return this.auth.enroll(auth, dto);
  }

  @ApiBearerAuth()
  @Get('devices')
  list(@CurrentAuth() auth: AuthContext) {
    return this.auth.list(auth);
  }

  @ApiBearerAuth()
  @Delete('devices/:id')
  @HttpCode(204)
  async revoke(@CurrentAuth() auth: AuthContext, @Param('id') id: string): Promise<void> {
    await this.auth.revoke(auth, id);
  }

  @ApiBearerAuth()
  @Get('me')
  me(@CurrentAuth() auth: AuthContext): AuthContext {
    return auth;
  }
}

