import { Injectable, type CanActivate, type ExecutionContext, UnauthorizedException } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import type { Request } from 'express';
import { AuthService } from './auth.service.js';
import type { AuthContext } from './auth.types.js';
import { IS_PUBLIC } from './public.decorator.js';

type AuthenticatedRequest = Request & { auth?: AuthContext };

@Injectable()
export class AuthGuard implements CanActivate {
  constructor(
    private readonly reflector: Reflector,
    private readonly authService: AuthService,
  ) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    if (this.reflector.getAllAndOverride<boolean>(IS_PUBLIC, [context.getHandler(), context.getClass()])) {
      return true;
    }
    const request = context.switchToHttp().getRequest<AuthenticatedRequest>();
    const header = request.header('authorization');
    const match = /^Bearer ([A-Za-z0-9_-]+)$/.exec(header ?? '');
    if (!match?.[1]) throw new UnauthorizedException('Missing bearer token');
    const auth = await this.authService.authenticate(match[1]);
    if (!auth) throw new UnauthorizedException('Invalid or revoked device token');
    request.auth = auth;
    return true;
  }
}

