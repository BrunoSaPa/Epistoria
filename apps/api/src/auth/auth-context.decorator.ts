import { createParamDecorator, type ExecutionContext } from '@nestjs/common';
import type { Request } from 'express';
import type { AuthContext } from './auth.types.js';

type AuthenticatedRequest = Request & { auth?: AuthContext };

export const CurrentAuth = createParamDecorator(
  (_data: unknown, context: ExecutionContext): AuthContext => {
    const request = context.switchToHttp().getRequest<AuthenticatedRequest>();
    if (!request.auth) throw new Error('Auth guard did not attach a context');
    return request.auth;
  },
);

