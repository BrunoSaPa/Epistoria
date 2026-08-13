import { Injectable, type OnModuleDestroy, type OnModuleInit } from '@nestjs/common';
import { PrismaPg } from '@prisma/adapter-pg';
import { environment } from '../config/environment.js';
import { PrismaClient } from '../generated/prisma/client.js';

@Injectable()
export class PrismaService extends PrismaClient implements OnModuleInit, OnModuleDestroy {
  constructor() {
    const config = environment();
    const adapter = new PrismaPg({
      connectionString: config.databaseUrl,
      connectionTimeoutMillis: 5_000,
      idleTimeoutMillis: 10_000,
      max: config.nodeEnv === 'production' ? 10 : 5,
    });
    super({ adapter });
  }

  async onModuleInit(): Promise<void> {
    await this.$connect();
  }

  async onModuleDestroy(): Promise<void> {
    await this.$disconnect();
  }
}

