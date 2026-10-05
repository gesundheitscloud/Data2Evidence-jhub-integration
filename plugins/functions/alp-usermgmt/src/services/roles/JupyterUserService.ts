import type { Knex } from '../../types'
import { ROLES } from '../../const'
import { Inject, Service } from 'typedi'
import { User } from '../../entities'
import { UserGroupRepository, UserRepository } from '../../repositories'
import { B2cGroupService } from '../B2cGroupService'
import { UserGroupService } from '../UserGroupService'
import { createLogger } from '../../Logger'
import { IRoleService } from './IRoleService'

@Service()
export class JupyterUserService implements IRoleService {
  private static ROLE = ROLES.JUPYTER_USER
  private readonly logger = createLogger(this.constructor.name)

  constructor(
    @Inject('DB_CONNECTION') private readonly db: Knex,
    private readonly userRepo: UserRepository,
    private readonly userGroupRepo: UserGroupRepository,
    private readonly groupService: B2cGroupService,
    private readonly userGroupService: UserGroupService
  ) {}

  async getUsers(): Promise<User[]> {
    const subquery = this.db('user_group')
      .innerJoin('b2c_group', 'user_group.b2c_group_id', 'b2c_group.id')
      .where('b2c_group.role', JupyterUserService.ROLE)
      .select('user_group.user_id')

    return await this.db('user')
      .select()
      .where('id', 'in', subquery)
      .then(result => result.map(row => this.userRepo.reducer(row)) || [])
  }

  async getGroup() {
    return await this.groupService.getGroupByRole(JupyterUserService.ROLE)
  }

  async isGranted(userId: string): Promise<boolean> {
    if (!userId) return false
    const userGroups = await this.userGroupRepo.getList({ user_id: userId })
    if (userGroups.length === 0) return false
    const groups = await this.groupService.getGroupsByIds(userGroups.map(group => group.b2cGroupId))
    return groups.some(group => group.role === JupyterUserService.ROLE)
  }

  async registerUser(userId: string) {
    const group = await this.getGroup()
    if (!group?.id) {
      throw new Error(`Unable to find group for role ${JupyterUserService.ROLE}`)
    }
    this.logger.info(`Register ${JupyterUserService.ROLE} for ${userId}`)
    return await this.userGroupService.registerUserToGroup(userId, group.id)
  }

  async withdrawUser(userId: string) {
    const group = await this.getGroup()
    if (!group?.id) {
      throw new Error(`Unable to find group for role ${JupyterUserService.ROLE}`)
    }
    this.logger.info(`Withdraw ${JupyterUserService.ROLE} for ${userId}`)
    return await this.userGroupService.withdrawUserFromGroup(userId, group.id)
  }
}
